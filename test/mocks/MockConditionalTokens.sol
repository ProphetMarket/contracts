// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title MockConditionalTokens
/// @notice Minimal mock of the Gnosis Conditional Tokens Framework for testing the CTF Exchange.
/// @dev Implements the IConditionalTokens interface used by the exchange, with real ID computation
///      matching the Gnosis CTF spec. Not intended for production use.
contract MockConditionalTokens is ERC1155 {
    using SafeERC20 for IERC20;
    // ── State ─────────────────────────────────────────────────────

    mapping(bytes32 conditionId => uint256 outcomeSlotCount) public outcomeSlotCounts;
    mapping(bytes32 conditionId => uint256[]) private _payoutNumerators;
    mapping(bytes32 conditionId => uint256 denominator) public payoutDenominator;

    // ── Errors ────────────────────────────────────────────────────

    error ConditionAlreadyPrepared();
    error ConditionNotPrepared();
    error PayoutsAlreadyReported();
    error PayoutsLengthMismatch();
    error InvalidPartition();
    error InsufficientBalance();

    // ── Events (matching Gnosis CTF) ──────────────────────────────

    event ConditionPreparation(
        bytes32 indexed conditionId, address indexed oracle, bytes32 indexed questionId, uint256 outcomeSlotCount
    );
    event ConditionResolution(
        bytes32 indexed conditionId,
        address indexed oracle,
        bytes32 indexed questionId,
        uint256 outcomeSlotCount,
        uint256[] payoutNumerators
    );
    event PositionSplit(
        address indexed stakeholder,
        IERC20 collateralToken,
        bytes32 indexed parentCollectionId,
        bytes32 indexed conditionId,
        uint256[] partition,
        uint256 amount
    );
    event PositionsMerge(
        address indexed stakeholder,
        IERC20 collateralToken,
        bytes32 indexed parentCollectionId,
        bytes32 indexed conditionId,
        uint256[] partition,
        uint256 amount
    );
    event PayoutRedemption(
        address indexed redeemer,
        IERC20 indexed collateralToken,
        bytes32 indexed parentCollectionId,
        bytes32 conditionId,
        uint256[] indexSets,
        uint256 payout
    );

    // ── Constructor ───────────────────────────────────────────────

    constructor() ERC1155("") {}

    // ── IConditionalTokens implementation ─────────────────────────

    function prepareCondition(address oracle, bytes32 questionId, uint256 _outcomeSlotCount) external {
        bytes32 conditionId = getConditionId(oracle, questionId, _outcomeSlotCount);
        if (outcomeSlotCounts[conditionId] != 0) revert ConditionAlreadyPrepared();

        outcomeSlotCounts[conditionId] = _outcomeSlotCount;
        emit ConditionPreparation(conditionId, oracle, questionId, _outcomeSlotCount);
    }

    function reportPayouts(bytes32 questionId, uint256[] calldata payouts) external {
        bytes32 conditionId = getConditionId(msg.sender, questionId, payouts.length);
        if (outcomeSlotCounts[conditionId] == 0) revert ConditionNotPrepared();
        if (payoutDenominator[conditionId] != 0) revert PayoutsAlreadyReported();

        uint256 denominator;
        for (uint256 i = 0; i < payouts.length; i++) {
            denominator += payouts[i];
        }

        payoutDenominator[conditionId] = denominator;
        _payoutNumerators[conditionId] = payouts;

        emit ConditionResolution(conditionId, msg.sender, questionId, payouts.length, payouts);
    }

    function splitPosition(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata partition,
        uint256 amount
    ) external {
        if (outcomeSlotCounts[conditionId] == 0) revert ConditionNotPrepared();
        if (partition.length == 0) revert InvalidPartition();

        // Transfer collateral from caller to this contract
        IERC20(collateralToken).safeTransferFrom(msg.sender, address(this), amount);

        // Mint position tokens for each partition element
        for (uint256 i = 0; i < partition.length; i++) {
            bytes32 collectionId = getCollectionId(parentCollectionId, conditionId, partition[i]);
            uint256 positionId = getPositionId(collateralToken, collectionId);
            _mint(msg.sender, positionId, amount, "");
        }

        emit PositionSplit(msg.sender, collateralToken, parentCollectionId, conditionId, partition, amount);
    }

    function mergePositions(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata partition,
        uint256 amount
    ) external {
        if (outcomeSlotCounts[conditionId] == 0) revert ConditionNotPrepared();
        if (partition.length == 0) revert InvalidPartition();

        // Burn position tokens for each partition element
        for (uint256 i = 0; i < partition.length; i++) {
            bytes32 collectionId = getCollectionId(parentCollectionId, conditionId, partition[i]);
            uint256 positionId = getPositionId(collateralToken, collectionId);
            _burn(msg.sender, positionId, amount);
        }

        // Return collateral to caller
        IERC20(collateralToken).safeTransfer(msg.sender, amount);

        emit PositionsMerge(msg.sender, collateralToken, parentCollectionId, conditionId, partition, amount);
    }

    function redeemPositions(
        IERC20 collateralToken,
        bytes32 parentCollectionId,
        bytes32 conditionId,
        uint256[] calldata indexSets
    ) external {
        if (payoutDenominator[conditionId] == 0) revert ConditionNotPrepared();

        uint256 totalPayout;
        uint256[] memory numerators = _payoutNumerators[conditionId];
        uint256 denominator = payoutDenominator[conditionId];

        for (uint256 i = 0; i < indexSets.length; i++) {
            bytes32 collectionId = getCollectionId(parentCollectionId, conditionId, indexSets[i]);
            uint256 positionId = getPositionId(collateralToken, collectionId);
            uint256 posBalance = balanceOf(msg.sender, positionId);
            if (posBalance == 0) continue;

            // Calculate payout for this index set
            uint256 payoutNumerator;
            for (uint256 j = 0; j < numerators.length; j++) {
                if ((indexSets[i] & (1 << j)) != 0) {
                    payoutNumerator += numerators[j];
                }
            }

            uint256 payout = posBalance * payoutNumerator / denominator;
            totalPayout += payout;

            _burn(msg.sender, positionId, posBalance);
        }

        if (totalPayout > 0) {
            IERC20(collateralToken).safeTransfer(msg.sender, totalPayout);
        }

        emit PayoutRedemption(msg.sender, collateralToken, parentCollectionId, conditionId, indexSets, totalPayout);
    }

    // ── View / Pure functions ─────────────────────────────────────

    function payoutNumerators(bytes32 conditionId, uint256 index) external view returns (uint256) {
        return _payoutNumerators[conditionId][index];
    }

    function getOutcomeSlotCount(bytes32 conditionId) external view returns (uint256) {
        return outcomeSlotCounts[conditionId];
    }

    function getConditionId(address oracle, bytes32 questionId, uint256 outcomeSlotCount)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(oracle, questionId, outcomeSlotCount));
    }

    function getCollectionId(bytes32 parentCollectionId, bytes32 conditionId, uint256 indexSet)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encodePacked(parentCollectionId, conditionId, indexSet));
    }

    function getPositionId(IERC20 collateralToken, bytes32 collectionId) public pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(collateralToken, collectionId)));
    }
}
