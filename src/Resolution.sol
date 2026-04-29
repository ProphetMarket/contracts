// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IConditionalTokens} from "exchange/interfaces/IConditionalTokens.sol";

/// @title Resolution
/// @notice Stores AI oracle payout reports for Prophet prediction markets with a cooldown period
///         before finalization. After cooldown, payouts are forwarded to the Gnosis CTF atomically.
/// @dev The oracle submits payouts via `reportPayouts` (pending state). After the cooldown elapses,
///      anyone can call `finalizePayouts` to write permanent storage and forward to the CTF.
///      The admin (owner) can override a pending report or pause oracle submissions in emergencies.
///      There is no user-facing dispute mechanism — this is by design.
contract Resolution is Ownable2Step, Pausable {
    // ── Constants ────────────────────────────────────────────────────

    /// @notice Minimum allowed cooldown period (1 hour).
    uint256 public constant MIN_COOLDOWN = 1 hours;

    /// @notice Maximum allowed cooldown period (72 hours).
    uint256 public constant MAX_COOLDOWN = 72 hours;

    // ── Immutables ──────────────────────────────────────────────────

    /// @notice The Gnosis Conditional Tokens Framework contract.
    IConditionalTokens public immutable ctf;

    // ── State ───────────────────────────────────────────────────────

    /// @notice The address authorized to report payouts.
    address public oracle;

    /// @notice Seconds between oracle submission and earliest finalization.
    uint256 public cooldownPeriod;

    /// @notice Recorded payouts per conditionId (written on finalization only).
    mapping(bytes32 conditionId => uint256[] payouts) private _payouts;

    /// @notice Whether a conditionId has been finalized.
    mapping(bytes32 conditionId => bool) private _reported;

    /// @notice IPFS CID of the resolution reasoning per conditionId.
    mapping(bytes32 conditionId => string ipfsCid) private _ipfsCids;

    /// @notice Pending report awaiting cooldown expiry.
    struct PendingReport {
        uint256[] payouts;
        string ipfsCid;
        bytes32 questionId;
        uint256 finalizeAfter;
        bool exists;
    }

    /// @notice Pending reports per conditionId.
    mapping(bytes32 conditionId => PendingReport) private _pending;

    // ── Events ──────────────────────────────────────────────────────

    /// @notice Emitted when the oracle submits a report (enters cooldown).
    event PayoutsPending(bytes32 indexed conditionId, uint256[] payouts, string ipfsCid, uint256 finalizeAfter);

    /// @notice Emitted when a pending report is finalized and forwarded to the CTF.
    event PayoutsReported(bytes32 indexed conditionId, uint256[] payouts, string ipfsCid);

    /// @notice Emitted when the admin overrides a pending report.
    event ReportOverridden(bytes32 indexed conditionId, uint256[] newPayouts, string newIpfsCid, uint256 finalizeAfter);

    /// @notice Emitted when the oracle address is changed.
    event OracleTransferred(address indexed previousOracle, address indexed newOracle);

    /// @notice Emitted when the cooldown period is changed.
    event CooldownPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);

    // ── Errors ──────────────────────────────────────────────────────

    error Unauthorized();
    error AlreadyReported(bytes32 conditionId);
    error InvalidPayoutsLength(uint256 length);
    error InvalidPayoutValues();
    error ZeroAddress();
    error RenounceDisabled();
    error NoPendingReport(bytes32 conditionId);
    error CooldownNotElapsed(bytes32 conditionId, uint256 finalizeAfter);
    error ReportAlreadyPending(bytes32 conditionId);
    error ConditionQuestionIdMismatch(bytes32 conditionId, bytes32 expectedConditionId);
    error CooldownOutOfRange(uint256 value, uint256 min, uint256 max);

    // ── Modifiers ───────────────────────────────────────────────────

    modifier onlyOracle() {
        if (msg.sender != oracle) revert Unauthorized();
        _;
    }

    // ── Constructor ─────────────────────────────────────────────────

    /// @param initialOwner Admin address that can override reports and manage the oracle.
    /// @param initialOracle Address authorized to report payouts.
    /// @param ctfAddress Gnosis Conditional Tokens Framework contract address.
    /// @param initialCooldown Initial cooldown period in seconds (must be in [MIN_COOLDOWN, MAX_COOLDOWN]).
    constructor(address initialOwner, address initialOracle, address ctfAddress, uint256 initialCooldown)
        Ownable(initialOwner)
    {
        if (initialOracle == address(0)) revert ZeroAddress();
        if (ctfAddress == address(0)) revert ZeroAddress();
        if (initialCooldown < MIN_COOLDOWN || initialCooldown > MAX_COOLDOWN) {
            revert CooldownOutOfRange(initialCooldown, MIN_COOLDOWN, MAX_COOLDOWN);
        }

        oracle = initialOracle;
        ctf = IConditionalTokens(ctfAddress);
        cooldownPeriod = initialCooldown;

        emit OracleTransferred(address(0), initialOracle);
    }

    // ── Oracle functions ────────────────────────────────────────────

    /// @notice Submit a payout report. Enters pending state for the cooldown period.
    /// @param conditionId The condition identifier (from CTF prepareCondition).
    /// @param questionId The question identifier (needed for CTF forwarding on finalization).
    /// @param payouts Array of exactly 2 values: [1,0] YES wins, [0,1] NO wins, [1,1] cancelled.
    /// @param ipfsCid IPFS content identifier for resolution reasoning (may be empty).
    function reportPayouts(bytes32 conditionId, bytes32 questionId, uint256[] calldata payouts, string calldata ipfsCid)
        external
        onlyOracle
        whenNotPaused
    {
        if (_reported[conditionId]) revert AlreadyReported(conditionId);
        if (_pending[conditionId].exists) revert ReportAlreadyPending(conditionId);
        if (payouts.length != 2) revert InvalidPayoutsLength(payouts.length);
        if (!_validPayouts(payouts[0], payouts[1])) revert InvalidPayoutValues();

        // Verify conditionId was derived from this contract as the CTF oracle.
        // The Gnosis CTF computes conditionId = keccak256(oracle, questionId, outcomeSlotCount).
        // Since this contract is the oracle, the expected conditionId must match.
        bytes32 expectedConditionId = ctf.getConditionId(address(this), questionId, 2);
        if (conditionId != expectedConditionId) {
            revert ConditionQuestionIdMismatch(conditionId, expectedConditionId);
        }

        uint256 finalizeAfter = block.timestamp + cooldownPeriod;

        _pending[conditionId] = PendingReport({
            payouts: payouts, ipfsCid: ipfsCid, questionId: questionId, finalizeAfter: finalizeAfter, exists: true
        });

        emit PayoutsPending(conditionId, payouts, ipfsCid, finalizeAfter);
    }

    /// @notice Finalize a pending report after the cooldown has elapsed.
    ///         Writes permanent storage, emits PayoutsReported, and forwards to the CTF.
    ///         Callable by anyone — security comes from the time delay.
    /// @param conditionId The condition identifier to finalize.
    function finalizePayouts(bytes32 conditionId) external {
        PendingReport memory p = _pending[conditionId];
        if (!p.exists) revert NoPendingReport(conditionId);
        if (block.timestamp < p.finalizeAfter) revert CooldownNotElapsed(conditionId, p.finalizeAfter);

        // Write permanent storage.
        _reported[conditionId] = true;
        _payouts[conditionId] = p.payouts;
        _ipfsCids[conditionId] = p.ipfsCid;

        // Clear pending state (gas refund).
        delete _pending[conditionId];

        emit PayoutsReported(conditionId, p.payouts, p.ipfsCid);

        // Forward to CTF so users can redeem collateral (fixes H-02).
        ctf.reportPayouts(p.questionId, p.payouts);
    }

    // ── Admin functions ─────────────────────────────────────────────

    /// @notice Override a pending report with a corrected outcome and reset the cooldown.
    ///         Only callable by the admin (owner). Works even when paused.
    /// @param conditionId The condition identifier with a pending report.
    /// @param payouts New payout vector: [1,0], [0,1], or [1,1].
    /// @param ipfsCid New IPFS CID for the override reasoning.
    function overrideReport(bytes32 conditionId, uint256[] calldata payouts, string calldata ipfsCid)
        external
        onlyOwner
    {
        if (!_pending[conditionId].exists) revert NoPendingReport(conditionId);
        if (payouts.length != 2) revert InvalidPayoutsLength(payouts.length);
        if (!_validPayouts(payouts[0], payouts[1])) revert InvalidPayoutValues();

        uint256 finalizeAfter = block.timestamp + cooldownPeriod;

        // Preserve the original questionId — the market identity doesn't change.
        _pending[conditionId].payouts = payouts;
        _pending[conditionId].ipfsCid = ipfsCid;
        _pending[conditionId].finalizeAfter = finalizeAfter;

        emit ReportOverridden(conditionId, payouts, ipfsCid, finalizeAfter);
    }

    /// @notice Transfer the oracle role to a new address.
    /// @param newOracle The new oracle address.
    function setOracle(address newOracle) external onlyOwner {
        if (newOracle == address(0)) revert ZeroAddress();
        address prev = oracle;
        oracle = newOracle;
        emit OracleTransferred(prev, newOracle);
    }

    /// @notice Update the cooldown period. Does not affect already-pending reports.
    /// @param newPeriod New cooldown in seconds (must be in [MIN_COOLDOWN, MAX_COOLDOWN]).
    function setCooldownPeriod(uint256 newPeriod) external onlyOwner {
        if (newPeriod < MIN_COOLDOWN || newPeriod > MAX_COOLDOWN) {
            revert CooldownOutOfRange(newPeriod, MIN_COOLDOWN, MAX_COOLDOWN);
        }
        uint256 oldPeriod = cooldownPeriod;
        cooldownPeriod = newPeriod;
        emit CooldownPeriodUpdated(oldPeriod, newPeriod);
    }

    /// @notice Pause oracle submissions. Override and finalization remain available.
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpause oracle submissions.
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Disabled — renouncing ownership would permanently brick oracle management.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ── View functions ──────────────────────────────────────────────

    /// @notice Get the recorded payouts for a finalized conditionId.
    /// @param conditionId The condition identifier.
    /// @return The payout array (empty if not finalized).
    function getPayouts(bytes32 conditionId) external view returns (uint256[] memory) {
        return _payouts[conditionId];
    }

    /// @notice Check whether payouts have been finalized for a conditionId.
    /// @param conditionId The condition identifier.
    /// @return True if finalized.
    function isReported(bytes32 conditionId) external view returns (bool) {
        return _reported[conditionId];
    }

    /// @notice Get the IPFS CID of the resolution reasoning for a finalized conditionId.
    /// @param conditionId The condition identifier.
    /// @return The IPFS CID (empty string if not set or not finalized).
    function getIpfsCid(bytes32 conditionId) external view returns (string memory) {
        return _ipfsCids[conditionId];
    }

    /// @notice Check whether a conditionId has a pending (non-finalized) report.
    /// @param conditionId The condition identifier.
    /// @return True if a report is pending.
    function isPending(bytes32 conditionId) external view returns (bool) {
        return _pending[conditionId].exists;
    }

    /// @notice Get the full pending report for a conditionId.
    /// @param conditionId The condition identifier.
    /// @return payouts The pending payout vector.
    /// @return ipfsCid The pending IPFS CID.
    /// @return questionId The question identifier for CTF forwarding.
    /// @return finalizeAfter The earliest timestamp at which finalization is allowed.
    /// @return exists Whether a pending report exists.
    function getPendingReport(bytes32 conditionId)
        external
        view
        returns (
            uint256[] memory payouts,
            string memory ipfsCid,
            bytes32 questionId,
            uint256 finalizeAfter,
            bool exists
        )
    {
        PendingReport memory p = _pending[conditionId];
        return (p.payouts, p.ipfsCid, p.questionId, p.finalizeAfter, p.exists);
    }

    // ── Internal ────────────────────────────────────────────────────

    /// @dev Validates the payout vector. Accepts [1,0] (YES wins), [0,1] (NO wins),
    ///      and [1,1] (cancellation — the Gnosis CTF redeems each token at $0.50).
    ///      Rejects [0,0] which would lock collateral permanently.
    function _validPayouts(uint256 a, uint256 b) private pure returns (bool) {
        return (a == 1 && b == 0) || (a == 0 && b == 1) || (a == 1 && b == 1);
    }
}
