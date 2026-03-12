// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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

/// @title ProphetCTFExchange
/// @notice Prophet's deployment of the Polymarket CTF Exchange (MIT).
/// @dev Thin wrapper around the Polymarket exchange mixins with compatible Solidity pragma.
///      The original CTFExchange.sol pins `pragma solidity 0.8.15` which conflicts with
///      OpenZeppelin v5 (`^0.8.20`). This wrapper uses the same mixins (all `<0.9.0`)
///      and is functionally identical to the original.
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
    error NotAdminOrOperator();

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

    function registerToken(uint256 token, uint256 complement, bytes32 conditionId) external {
        if (admins[msg.sender] != 1 && operators[msg.sender] != 1) revert NotAdminOrOperator();
        _registerToken(token, complement, conditionId);
    }
}
