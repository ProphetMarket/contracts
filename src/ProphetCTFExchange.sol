// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {IERC1155} from "openzeppelin-contracts/token/ERC1155/IERC1155.sol";

import {Auth} from "exchange/mixins/Auth.sol";
import {Fees} from "exchange/mixins/Fees.sol";
import {Assets} from "exchange/mixins/Assets.sol";
import {Hashing} from "exchange/mixins/Hashing.sol";
import {Trading} from "exchange/mixins/Trading.sol";
import {Registry} from "exchange/mixins/Registry.sol";
import {Pausable} from "exchange/mixins/Pausable.sol";
import {Signatures} from "exchange/mixins/Signatures.sol";
import {NonceManager} from "exchange/mixins/NonceManager.sol";
import {AssetOperations} from "exchange/mixins/AssetOperations.sol";
import {BaseExchange} from "exchange/BaseExchange.sol";
import {Order} from "exchange/libraries/OrderStructs.sol";
import {IConditionalTokens} from "exchange/interfaces/IConditionalTokens.sol";

/// @title ProphetCTFExchange
/// @notice Prophet's deployment of the Polymarket CTF Exchange (MIT).
/// @dev Thin wrapper around the Polymarket exchange mixins with compatible Solidity pragma.
///      The original CTFExchange.sol pins `pragma solidity 0.8.15` which conflicts with
///      OpenZeppelin v5 (`^0.8.20`). This wrapper uses the same mixins (all `<0.9.0`)
///      and is functionally identical to the original, except for the market-lifecycle
///      role split: `registerToken` requires the admin or oracle role (not operator),
///      and inputs are validated on-chain against the CTF contract.
contract ProphetCTFExchange is
    BaseExchange,
    Auth,
    Assets,
    Fees,
    Pausable,
    AssetOperations,
    Hashing("Prophet CTF Exchange", "1"),
    NonceManager,
    Registry,
    Signatures,
    Trading
{
    /// @notice Address authorized to call `registerToken`. Set by admin via `setOracle`.
    ///         Should match the oracle configured on `Resolution.sol` — the oracle role
    ///         handles the full market lifecycle (register tokens, report payouts).
    address public oracle;

    /// @notice The Resolution contract address. Used to verify that conditions were prepared
    ///         with Resolution as the CTF oracle.
    address public resolution;

    error NotAdminOrOracle();
    error TokenConditionMismatch();
    error ConditionNotPrepared();
    error WrongConditionOracle();
    error DuplicatedConditionId();

    event OracleUpdated(address indexed previousOracle, address indexed newOracle);
    event ResolutionUpdated(address indexed previousResolution, address indexed newResolution);
    event TokenUnregistered(uint256 indexed token0, uint256 indexed token1, bytes32 indexed conditionId);

    /// @notice Conditions that have been unregistered. Prevents re-registration of the
    ///         same condition, which would reactivate stale signed orders at outdated prices.
    mapping(bytes32 conditionId => bool) public previousConditionIds;

    constructor(address _collateral, address _ctf, address _proxyFactory, address _safeFactory)
        Assets(_requireNonZero(_collateral), _requireNonZero(_ctf))
        Signatures(_proxyFactory, _safeFactory)
    {}

    /// @dev Validates a constructor argument is non-zero before passing it to parent constructors.
    function _requireNonZero(address addr) private pure returns (address) {
        if (addr == address(0)) revert ZeroAddress();
        return addr;
    }

    // ── Pause ─────────────────────────────────────────────────────

    function pauseTrading() external onlyAdmin {
        _pauseTrading();
    }

    function unpauseTrading() external onlyAdmin {
        _unpauseTrading();
    }

    // ── Trading ───────────────────────────────────────────────────

    /// @notice Fills a single signed maker order.
    /// @dev OPERATOR TRUST ASSUMPTION: Only operators can call this function. The operator
    ///      has exclusive visibility of the off-chain order book and full discretion over
    ///      which orders to fill, in what sequence, and against which counterparties.
    ///      Users should be aware that the operator can selectively execute or withhold fills.
    ///      This design is inherited from the Polymarket CTF Exchange architecture.
    function fillOrder(Order memory order, uint256 fillAmount) external nonReentrant onlyOperator notPaused {
        _fillOrder(order, fillAmount, msg.sender);
    }

    /// @notice Fills multiple signed maker orders in a single transaction.
    /// @dev OPERATOR TRUST ASSUMPTION: See fillOrder. All orders in a batch are selected
    ///      and sequenced at the operator's sole discretion.
    function fillOrders(Order[] memory orders, uint256[] memory fillAmounts)
        external
        nonReentrant
        onlyOperator
        notPaused
    {
        _fillOrders(orders, fillAmounts, msg.sender);
    }

    /// @notice Matches a taker order against one or more maker orders.
    /// @dev OPERATOR TRUST ASSUMPTION: See fillOrder. The operator selects which taker order
    ///      is matched against which maker orders, and controls fill amounts for each pair.
    function matchOrders(
        Order memory takerOrder,
        Order[] memory makerOrders,
        uint256 takerFillAmount,
        uint256[] memory makerFillAmounts
    ) external nonReentrant onlyOperator notPaused {
        _matchOrders(takerOrder, makerOrders, takerFillAmount, makerFillAmounts);
    }

    // ── Fee Sweeping ──────────────────────────────────────────────

    /// @notice Merges complementary YES+NO fee balances back into collateral.
    /// @dev The operator accumulates fees in outcome tokens during order fills.
    ///      This function converts equal amounts of YES+NO tokens into collateral
    ///      by pulling both tokens into the exchange, merging via the CTF, and
    ///      returning the resulting collateral to the operator.
    /// @param tokenId Either outcome token of the pair whose fees to sweep
    function sweepFees(uint256 tokenId) external nonReentrant onlyOperator {
        uint256 complement = getComplement(tokenId);
        bytes32 conditionId = getConditionId(tokenId);

        address ctfAddr = getCtf();
        uint256 balToken = IERC1155(ctfAddr).balanceOf(msg.sender, tokenId);
        uint256 balComplement = IERC1155(ctfAddr).balanceOf(msg.sender, complement);

        uint256 amount = balToken < balComplement ? balToken : balComplement;
        if (amount == 0) revert NothingToSweep();

        _transfer(msg.sender, address(this), tokenId, amount);
        _transfer(msg.sender, address(this), complement, amount);
        _merge(conditionId, amount);
        _transfer(address(this), msg.sender, 0, amount);

        emit FeesSwept(msg.sender, tokenId, amount);
    }

    // ── Configuration ─────────────────────────────────────────────

    function setProxyFactory(address _newProxyFactory) external onlyAdmin {
        _scheduleProxyFactory(_newProxyFactory);
    }

    function applyProxyFactory() external onlyAdmin {
        _applyProxyFactory();
    }

    function cancelProxyFactory() external onlyAdmin {
        _cancelProxyFactory();
    }

    function setSafeFactory(address _newSafeFactory) external onlyAdmin {
        _scheduleSafeFactory(_newSafeFactory);
    }

    function applySafeFactory() external onlyAdmin {
        _applySafeFactory();
    }

    function cancelSafeFactory() external onlyAdmin {
        _cancelSafeFactory();
    }

    /// @notice Update the oracle address authorized to call `registerToken`.
    /// @param _oracle The new oracle EOA. Must be non-zero.
    function setOracle(address _oracle) external onlyAdmin {
        if (_oracle == address(0)) revert ZeroAddress();
        address prev = oracle;
        oracle = _oracle;
        emit OracleUpdated(prev, _oracle);
    }

    /// @notice Set the Resolution contract address used for condition oracle validation.
    /// @param _resolution The Resolution contract address. Must be non-zero.
    function setResolution(address _resolution) external onlyAdmin {
        if (_resolution == address(0)) revert ZeroAddress();
        address prev = resolution;
        resolution = _resolution;
        emit ResolutionUpdated(prev, _resolution);
    }

    // ── Registry ──────────────────────────────────────────────────

    /// @notice Register a YES/NO token pair for a prepared CTF condition.
    /// @dev Callable by admin or oracle. Inputs are validated on-chain against the
    ///      CTF contract: a compromised oracle cannot bind a valid token pair to the
    ///      wrong conditionId — the math won't check out.
    /// @param questionId The question identifier used when preparing the condition.
    ///        Used to verify the condition was prepared with Resolution as the CTF oracle.
    function registerToken(uint256 token, uint256 complement, bytes32 conditionId, bytes32 questionId)
        external
        notPaused
    {
        if (admins[msg.sender] != 1 && msg.sender != oracle) revert NotAdminOrOracle();
        _validateTokenCondition(token, complement, conditionId, questionId);
        _registerToken(token, complement, conditionId);
    }

    /// @notice Admin-only escape hatch to permanently remove a bad registration.
    /// @dev `_registerToken` is write-once in the upstream Registry mixin, so without
    ///      this there is no way to recover from an edge case (e.g. a condition that
    ///      was prepared incorrectly in the CTF itself). Both directions of the
    ///      registry mapping are cleared. The conditionId is tombstoned in
    ///      `previousConditionIds` to prevent re-registration, which would reactivate
    ///      stale signed orders at outdated prices.
    ///      The caller must provide both token IDs. The complement is validated against
    ///      storage — if it doesn't match, the call reverts. This acts as a double-check:
    ///      the admin must prove they know the exact pair they're deleting.
    function unregisterToken(uint256 token, uint256 complement) external onlyAdmin {
        if (registry[token].complement == 0) revert InvalidTokenId();
        if (registry[token].complement != complement) revert InvalidComplement();
        bytes32 conditionId = registry[token].conditionId;
        previousConditionIds[conditionId] = true;
        delete registry[token];
        delete registry[complement];
        emit TokenUnregistered(token, complement, conditionId);
    }

    /// @dev Validates that the condition exists in the CTF (was prepared as a binary
    ///      market) and that the token pair corresponds to the conditionId by
    ///      reconstructing the expected position IDs from the CTF contract.
    ///      IMPORTANT: getCollectionId / getPositionId are pure math functions that
    ///      return deterministic hashes regardless of whether prepareCondition was called.
    ///      The getOutcomeSlotCount check is therefore essential — it is the only guard
    ///      that rejects phantom (unprepared) conditions.
    function _validateTokenCondition(uint256 token, uint256 complement, bytes32 conditionId, bytes32 questionId)
        internal
        view
    {
        // Reject conditions that were previously unregistered. Re-registering the same
        // condition would reactivate stale signed orders at outdated prices.
        if (previousConditionIds[conditionId]) revert DuplicatedConditionId();

        IConditionalTokens ctfContract = IConditionalTokens(ctf);
        IERC20 collateralToken = IERC20(collateral);

        // Verify the condition was prepared in the CTF with exactly 2 outcome slots.
        // getOutcomeSlotCount returns 0 for conditions that were never prepared.
        if (ctfContract.getOutcomeSlotCount(conditionId) != 2) revert ConditionNotPrepared();

        bytes32 collectionYes = ctfContract.getCollectionId(bytes32(0), conditionId, 1);
        bytes32 collectionNo = ctfContract.getCollectionId(bytes32(0), conditionId, 2);

        uint256 expectedYes = ctfContract.getPositionId(collateralToken, collectionYes);
        uint256 expectedNo = ctfContract.getPositionId(collateralToken, collectionNo);

        bool valid =
            (token == expectedYes && complement == expectedNo) || (token == expectedNo && complement == expectedYes);

        if (!valid) revert TokenConditionMismatch();

        // Verify the condition was prepared with the Resolution contract as the CTF oracle.
        // This prevents conditions prepared by an attacker (bypassing Resolution) from
        // being registered, which would allow resolution without cooldown or admin oversight.
        // Runtime derivation: conditionId = keccak256(oracle, questionId, outcomeSlotCount).
        bytes32 expectedId = ctfContract.getConditionId(resolution, questionId, 2);
        if (conditionId != expectedId) revert WrongConditionOracle();
    }
}
