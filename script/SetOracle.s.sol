// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

import {Resolution} from "../src/Resolution.sol";

/// @title SetOracle
/// @notice Transfers the oracle role on an already-deployed Resolution contract.
/// @dev Idempotent: checks the current oracle before calling `setOracle`.
///      Must be run by the owner of the Resolution contract (deployer key).
///
///      Usage (keystore):
///        cast wallet import prophet-deployer --interactive
///        forge script script/SetOracle.s.sol --sig "run()" --account prophet-deployer --sender <DEPLOYER_ADDR> --rpc-url $RPC_URL --broadcast
///
///      Usage (hardware wallet):
///        forge script script/SetOracle.s.sol --sig "run()" --ledger --sender <DEPLOYER_ADDR> --rpc-url $RPC_URL --broadcast
///
///      Required env vars:
///        RESOLUTION_ADDRESS — deployed Resolution contract address
///        ORACLE_ADDRESS     — new oracle wallet to set
contract SetOracle is Script {
    error ResolutionAddressRequired();
    error OracleAddressRequired();

    /// @notice CLI entry point — signer resolved from CLI flags (--account, --ledger, etc.).
    function run() external {
        address resolution = vm.envAddress("RESOLUTION_ADDRESS");
        address oracle = vm.envAddress("ORACLE_ADDRESS");

        if (resolution == address(0)) revert ResolutionAddressRequired();
        if (oracle == address(0)) revert OracleAddressRequired();

        vm.startBroadcast();
        _setOracle(resolution, oracle);
        vm.stopBroadcast();
    }

    /// @notice Test entry point — broadcasts as the given address, reads config from env vars.
    function run(address deployer) external {
        address resolution = vm.envAddress("RESOLUTION_ADDRESS");
        address oracle = vm.envAddress("ORACLE_ADDRESS");

        if (resolution == address(0)) revert ResolutionAddressRequired();
        if (oracle == address(0)) revert OracleAddressRequired();

        vm.startBroadcast(deployer);
        _setOracle(resolution, oracle);
        vm.stopBroadcast();
    }

    /// @notice Test entry point — config passed directly (no env vars).
    function run(address deployer, address resolution, address oracle) external {
        if (resolution == address(0)) revert ResolutionAddressRequired();
        if (oracle == address(0)) revert OracleAddressRequired();

        vm.startBroadcast(deployer);
        _setOracle(resolution, oracle);
        vm.stopBroadcast();
    }

    function _setOracle(address resolution, address newOracle) internal {
        Resolution res = Resolution(resolution);

        if (res.oracle() == newOracle) {
            console.log("[SKIP] Oracle already set to:", newOracle);
            return;
        }

        res.setOracle(newOracle);
        console.log("[CONFIG] Set oracle:", newOracle);
    }
}
