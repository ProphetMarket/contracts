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

    // ── Events ───────────────────────────────────────────────────────

    event PayoutsReported(bytes32 indexed conditionId, uint256[] payouts);
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
        if (msg.sender != oracle) revert Unauthorized();
        _;
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
    /// @param payouts Array of exactly 2 values, each 0 or 1, with exactly one winner.
    function reportPayouts(bytes32 conditionId, uint256[] calldata payouts) external onlyOracle {
        if (_reported[conditionId]) revert AlreadyReported(conditionId);
        if (payouts.length != 2) revert InvalidPayoutsLength(payouts.length);
        if (!_validPayouts(payouts[0], payouts[1])) revert InvalidPayoutValues();

        _reported[conditionId] = true;
        _payouts[conditionId] = payouts;

        emit PayoutsReported(conditionId, payouts);
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

    // ── Internal ─────────────────────────────────────────────────────

    /// @dev Validates that exactly one payout is 1 and the other is 0.
    function _validPayouts(uint256 a, uint256 b) private pure returns (bool) {
        return (a == 1 && b == 0) || (a == 0 && b == 1);
    }
}
