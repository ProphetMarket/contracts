// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title Resolution
/// @notice Stores AI oracle payout reports for Prophet prediction markets.
/// @dev The oracle role reports payouts per conditionId. Admin (owner) can transfer the oracle role.
contract Resolution is Ownable {
    /// @notice The address authorized to report payouts.
    address public oracle;

    /// @notice Recorded payouts per conditionId.
    mapping(bytes32 conditionId => uint256[] payouts) private _payouts;

    /// @notice Whether a conditionId has been reported.
    mapping(bytes32 conditionId => bool) private _reported;

    /// @notice IPFS CID of the resolution reasoning per conditionId.
    mapping(bytes32 conditionId => string ipfsCid) private _ipfsCids;

    // ── Events ───────────────────────────────────────────────────────

    event PayoutsReported(bytes32 indexed conditionId, uint256[] payouts, string ipfsCid);
    event OracleTransferred(address indexed previousOracle, address indexed newOracle);

    // ── Errors ───────────────────────────────────────────────────────

    error Unauthorized();
    error AlreadyReported(bytes32 conditionId);
    error InvalidPayoutsLength(uint256 length);
    error InvalidPayoutValues();
    error ZeroAddress();
    error RenounceDisabled();

    // ── Modifiers ────────────────────────────────────────────────────

    modifier onlyOracle() {
        _checkOracle();
        _;
    }

    function _checkOracle() private view {
        if (msg.sender != oracle) revert Unauthorized();
    }

    // ── Constructor ──────────────────────────────────────────────────

    /// @param initialOwner Admin address that can transfer the oracle role.
    /// @param initialOracle Address authorized to report payouts.
    constructor(address initialOwner, address initialOracle) Ownable(initialOwner) {
        if (initialOracle == address(0)) revert ZeroAddress();
        oracle = initialOracle;
        emit OracleTransferred(address(0), initialOracle);
    }

    // ── Oracle functions ─────────────────────────────────────────────

    /// @notice Record payouts for a conditionId. Callable only by the oracle.
    /// @param conditionId The condition identifier (from CTF prepareCondition).
    /// @param payouts Array of exactly 2 values. Allowed vectors:
    ///                [1,0] (YES wins), [0,1] (NO wins), or [1,1] (market cancelled — 50/50 split).
    /// @param ipfsCid IPFS content identifier for resolution reasoning (may be empty).
    function reportPayouts(bytes32 conditionId, uint256[] calldata payouts, string calldata ipfsCid)
        external
        onlyOracle
    {
        if (_reported[conditionId]) revert AlreadyReported(conditionId);
        if (payouts.length != 2) revert InvalidPayoutsLength(payouts.length);
        if (!_validPayouts(payouts[0], payouts[1])) revert InvalidPayoutValues();

        _reported[conditionId] = true;
        _payouts[conditionId] = payouts;
        _ipfsCids[conditionId] = ipfsCid;

        emit PayoutsReported(conditionId, payouts, ipfsCid);
    }

    // ── Admin functions ──────────────────────────────────────────────

    /// @notice Transfer the oracle role to a new address.
    /// @param newOracle The new oracle address.
    function setOracle(address newOracle) external onlyOwner {
        if (newOracle == address(0)) revert ZeroAddress();
        address prev = oracle;
        oracle = newOracle;
        emit OracleTransferred(prev, newOracle);
    }

    /// @notice Disabled — renouncing ownership would permanently brick oracle management.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    // ── View functions ───────────────────────────────────────────────

    /// @notice Get the recorded payouts for a conditionId.
    /// @param conditionId The condition identifier.
    /// @return The payout array (empty if not reported).
    function getPayouts(bytes32 conditionId) external view returns (uint256[] memory) {
        return _payouts[conditionId];
    }

    /// @notice Check whether payouts have been reported for a conditionId.
    /// @param conditionId The condition identifier.
    /// @return True if reported.
    function isReported(bytes32 conditionId) external view returns (bool) {
        return _reported[conditionId];
    }

    /// @notice Get the IPFS CID of the resolution reasoning for a conditionId.
    /// @param conditionId The condition identifier.
    /// @return The IPFS CID (empty string if not set or not reported).
    function getIpfsCid(bytes32 conditionId) external view returns (string memory) {
        return _ipfsCids[conditionId];
    }

    // ── Internal ─────────────────────────────────────────────────────

    /// @dev Validates the payout vector. Accepts [1,0] (YES wins), [0,1] (NO wins),
    ///      and [1,1] (cancellation — the Gnosis CTF redeems each token at $0.50 under
    ///      this vector, splitting collateral 50/50 across all holders). Rejects [0,0]
    ///      which would lock collateral permanently.
    function _validPayouts(uint256 a, uint256 b) private pure returns (bool) {
        return (a == 1 && b == 0) || (a == 0 && b == 1) || (a == 1 && b == 1);
    }
}
