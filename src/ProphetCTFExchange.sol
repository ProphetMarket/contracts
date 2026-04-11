// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

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

    error NotAdminOrOracle();
    error TokenConditionMismatch();
    error ZeroAddress();

    event OracleUpdated(address indexed previousOracle, address indexed newOracle);
    event TokenUnregistered(uint256 indexed token0, uint256 indexed token1, bytes32 indexed conditionId);

    constructor(address _collateral, address _ctf, address _proxyFactory, address _safeFactory)
        Assets(_collateral, _ctf)
        Signatures(_proxyFactory, _safeFactory)
    {}

    // ── Pause ─────────────────────────────────────────────────────

    function pauseTrading() external onlyAdmin {
        _pauseTrading();
    }

    function unpauseTrading() external onlyAdmin {
        _unpauseTrading();
    }

    // ── Trading ───────────────────────────────────────────────────

    function fillOrder(Order memory order, uint256 fillAmount) external nonReentrant onlyOperator notPaused {
        _fillOrder(order, fillAmount, msg.sender);
    }

    function fillOrders(Order[] memory orders, uint256[] memory fillAmounts)
        external
        nonReentrant
        onlyOperator
        notPaused
    {
        _fillOrders(orders, fillAmounts, msg.sender);
    }

    function matchOrders(
        Order memory takerOrder,
        Order[] memory makerOrders,
        uint256 takerFillAmount,
        uint256[] memory makerFillAmounts
    ) external nonReentrant onlyOperator notPaused {
        _matchOrders(takerOrder, makerOrders, takerFillAmount, makerFillAmounts);
    }

    // ── Configuration ─────────────────────────────────────────────

    function setProxyFactory(address _newProxyFactory) external onlyAdmin {
        _setProxyFactory(_newProxyFactory);
    }

    function setSafeFactory(address _newSafeFactory) external onlyAdmin {
        _setSafeFactory(_newSafeFactory);
    }

    /// @notice Update the oracle address authorized to call `registerToken`.
    /// @param _oracle The new oracle EOA. Must be non-zero.
    function setOracle(address _oracle) external onlyAdmin {
        if (_oracle == address(0)) revert ZeroAddress();
        address prev = oracle;
        oracle = _oracle;
        emit OracleUpdated(prev, _oracle);
    }

    // ── Registry ──────────────────────────────────────────────────

    /// @notice Register a YES/NO token pair for a prepared CTF condition.
    /// @dev Callable by admin or oracle. Inputs are validated on-chain against the
    ///      CTF contract: a compromised oracle cannot bind a valid token pair to the
    ///      wrong conditionId — the math won't check out.
    function registerToken(uint256 token, uint256 complement, bytes32 conditionId) external {
        if (admins[msg.sender] != 1 && msg.sender != oracle) revert NotAdminOrOracle();
        _validateTokenCondition(token, complement, conditionId);
        _registerToken(token, complement, conditionId);
    }

    /// @notice Admin-only escape hatch to clear a bad registration.
    /// @dev `_registerToken` is write-once in the upstream Registry mixin, so without
    ///      this there is no way to recover from an edge case (e.g. a condition that
    ///      was prepared incorrectly in the CTF itself). Both directions of the
    ///      registry mapping are cleared so the pair can be re-registered.
    function unregisterToken(uint256 token, uint256 complement) external onlyAdmin {
        bytes32 conditionId = registry[token].conditionId;
        delete registry[token];
        delete registry[complement];
        emit TokenUnregistered(token, complement, conditionId);
    }

    /// @dev Validates that the token pair actually corresponds to the conditionId
    ///      by reconstructing the expected position IDs from the CTF contract.
    ///      Requires the condition to have been prepared via `prepareCondition`;
    ///      otherwise `getCollectionId` will return a value that does not match
    ///      any real position and validation will revert.
    function _validateTokenCondition(uint256 token, uint256 complement, bytes32 conditionId) internal view {
        IConditionalTokens ctfContract = IConditionalTokens(ctf);
        IERC20 collateralToken = IERC20(collateral);

        bytes32 collectionYes = ctfContract.getCollectionId(bytes32(0), conditionId, 1);
        bytes32 collectionNo = ctfContract.getCollectionId(bytes32(0), conditionId, 2);

        uint256 expectedYes = ctfContract.getPositionId(collateralToken, collectionYes);
        uint256 expectedNo = ctfContract.getPositionId(collateralToken, collectionNo);

        bool valid =
            (token == expectedYes && complement == expectedNo) || (token == expectedNo && complement == expectedYes);

        if (!valid) revert TokenConditionMismatch();
    }
}
