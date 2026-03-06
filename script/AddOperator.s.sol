// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

import {ProphetCTFExchange} from "../src/ProphetCTFExchange.sol";

/// @title AddOperator
/// @notice Registers an operator wallet on an already-deployed ProphetCTFExchange.
/// @dev Idempotent: checks `isOperator` before calling `addOperator`.
///      Must be run by an admin of the exchange (deployer key).
///
///      Usage (keystore):
///        cast wallet import prophet-deployer --interactive
///        forge script script/AddOperator.s.sol --account prophet-deployer --sender <DEPLOYER_ADDR> --rpc-url $RPC_URL --broadcast
///
///      Usage (hardware wallet):
///        forge script script/AddOperator.s.sol --ledger --sender <DEPLOYER_ADDR> --rpc-url $RPC_URL --broadcast
///
///      Required env vars:
///        EXCHANGE_ADDRESS  — deployed ProphetCTFExchange address
///        OPERATOR_ADDRESS  — operator wallet to register
contract AddOperator is Script {
    error ExchangeAddressRequired();
    error OperatorAddressRequired();

    /// @notice CLI entry point — signer resolved from CLI flags (--account, --ledger, etc.).
    function run() external {
        address exchange = vm.envAddress("EXCHANGE_ADDRESS");
        address operator = vm.envAddress("OPERATOR_ADDRESS");

        if (exchange == address(0)) revert ExchangeAddressRequired();
        if (operator == address(0)) revert OperatorAddressRequired();

        vm.startBroadcast();
        _addOperator(exchange, operator);
        vm.stopBroadcast();
    }

    /// @notice Test entry point — broadcasts as the given address (simulation only, no key needed).
    function run(address deployer) external {
        address exchange = vm.envAddress("EXCHANGE_ADDRESS");
        address operator = vm.envAddress("OPERATOR_ADDRESS");

        if (exchange == address(0)) revert ExchangeAddressRequired();
        if (operator == address(0)) revert OperatorAddressRequired();

        vm.startBroadcast(deployer);
        _addOperator(exchange, operator);
        vm.stopBroadcast();
    }

    function _addOperator(address exchange, address operator) internal {
        ProphetCTFExchange ex = ProphetCTFExchange(exchange);

        if (ex.isOperator(operator)) {
            console.log("[SKIP] Operator already registered:", operator);
            return;
        }

        ex.addOperator(operator);
        console.log("[CONFIG] Added operator:", operator);
    }
}
