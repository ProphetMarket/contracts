// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

import {TestUSDC} from "../src/TestUSDC.sol";
import {Resolution} from "../src/Resolution.sol";
import {ProphetCTFExchange} from "../src/ProphetCTFExchange.sol";
import {MockConditionalTokens} from "../test/mocks/MockConditionalTokens.sol";

/// @dev Extended interface for the Poly SafeProxyFactory. The exchange only uses
///      masterCopy(); proxyCreationCode() is added here for the H-03 deployment assertion.
interface IPolySafeProxyFactory {
    function masterCopy() external view returns (address);
    function proxyCreationCode() external pure returns (bytes memory);
}

/// @param deployedUsdc        Pre-deployed TestUSDC (address(0) = deploy fresh)
/// @param deployedCtf         Pre-deployed ConditionalTokens (address(0) = deploy fresh)
/// @param deployedResolution  Pre-deployed Resolution (address(0) = deploy fresh)
/// @param deployedExchange    Pre-deployed ProphetCTFExchange (address(0) = deploy fresh)
/// @param operatorAddress     Register as operator on exchange (address(0) = skip)
/// @param adminAddress        Register as admin on exchange (address(0) = skip)
/// @param oracleAddress       Set as the exchange oracle (address(0) = skip).
///                            The oracle is authorized to call `registerToken` and should
///                            match the oracle configured on Resolution.sol.
/// @param safeFactoryAddress  Poly SafeProxyFactory address (required for fresh exchange deploy).
///                            Passed as _safeFactory (4th constructor arg) for POLY_GNOSIS_SAFE signature validation.
///                            The exchange reads the singleton via safeFactory.masterCopy().
/// @param cooldownPeriod      Resolution cooldown in seconds (0 = use default 12 hours).
///                            Must be in [1 hour, 72 hours] when non-zero.
struct DeployConfig {
    address deployedUsdc;
    address deployedCtf;
    address deployedResolution;
    address deployedExchange;
    address operatorAddress;
    address adminAddress;
    address oracleAddress;
    address safeFactoryAddress;
    uint256 cooldownPeriod;
}

/// @title Deploy
/// @notice Deploys all Prophet contracts to Polygon Amoy in the correct order.
/// @dev Idempotent: set DEPLOYED_USDC, DEPLOYED_CTF, DEPLOYED_RESOLUTION, or DEPLOYED_EXCHANGE
///      environment variables to skip already-deployed contracts. Each is validated via code-size
///      check before being accepted.
///
///      Usage (keystore):
///        cast wallet import prophet-deployer --interactive
///        forge script script/Deploy.s.sol --account prophet-deployer --sender <DEPLOYER_ADDR> --rpc-url $RPC_URL --broadcast
///
///      Usage (hardware wallet):
///        forge script script/Deploy.s.sol --ledger --sender <DEPLOYER_ADDR> --rpc-url $RPC_URL --broadcast
///
///      Required env vars:
///        SAFE_FACTORY_ADDRESS   — Poly SafeProxyFactory (deploy via contracts-poly-safe/)
///
///      Optional env vars:
///        OPERATOR_ADDRESS    — register a separate operator on the exchange
///        ADMIN_ADDRESS       — transfer exchange admin to this address (deployer remains admin too)
///        ORACLE_ADDRESS      — set as the exchange oracle (authorized to call registerToken).
///                              Should match the oracle configured on Resolution.sol.
///        DEPLOYED_USDC       — skip TestUSDC deployment
///        DEPLOYED_CTF        — skip MockConditionalTokens deployment
///        DEPLOYED_RESOLUTION — skip Resolution deployment
///        DEPLOYED_EXCHANGE   — skip ProphetCTFExchange deployment
contract Deploy is Script {
    // ── Safe infrastructure ────────────────────────────────────────
    // Poly SafeProxyFactory deployed by contracts-poly-safe/script/DeployPolySafeFactory.s.sol.
    // Set via SAFE_FACTORY_ADDRESS env var. The exchange reads the singleton via factory.masterCopy().

    // ── Deployed addresses (populated during run()) ─────────────────
    address public deployedUsdc;
    address public deployedCtf;
    address public deployedResolution;
    address public deployedExchange;

    error MainnetNotSupported();

    /// @notice CLI entry point — signer resolved from CLI flags (--account, --ledger, etc.).
    function run() external {
        if (block.chainid == 137) revert MainnetNotSupported();

        vm.startBroadcast();
        _deploy(msg.sender, _configFromEnv());
        vm.stopBroadcast();
    }

    /// @notice Test entry point — broadcasts as the given address, reads config from env vars.
    function run(address deployer) external {
        if (block.chainid == 137) revert MainnetNotSupported();

        vm.startBroadcast(deployer);
        _deploy(deployer, _configFromEnv());
        vm.stopBroadcast();
    }

    /// @notice Test entry point — broadcasts as the given address, config passed directly (no env vars).
    function run(address deployer, DeployConfig memory cfg) external {
        if (block.chainid == 137) revert MainnetNotSupported();

        vm.startBroadcast(deployer);
        _deploy(deployer, cfg);
        vm.stopBroadcast();
    }

    function _configFromEnv() internal view returns (DeployConfig memory) {
        return DeployConfig({
            deployedUsdc: _envAddress("DEPLOYED_USDC"),
            deployedCtf: _envAddress("DEPLOYED_CTF"),
            deployedResolution: _envAddress("DEPLOYED_RESOLUTION"),
            deployedExchange: _envAddress("DEPLOYED_EXCHANGE"),
            operatorAddress: _envAddress("OPERATOR_ADDRESS"),
            adminAddress: _envAddress("ADMIN_ADDRESS"),
            oracleAddress: _envAddress("ORACLE_ADDRESS"),
            safeFactoryAddress: _envAddress("SAFE_FACTORY_ADDRESS"),
            cooldownPeriod: vm.envOr("RESOLUTION_COOLDOWN_SECONDS", uint256(12 hours))
        });
    }

    function _deploy(address deployer, DeployConfig memory cfg) internal {
        console.log("=== Prophet Contract Deployment ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);
        console.log("");

        address usdc = _deployUsdc(deployer, cfg.deployedUsdc);
        address ctf = _deployCtf(cfg.deployedCtf);
        address resolution = _deployResolution(deployer, ctf, cfg.deployedResolution, cfg.cooldownPeriod);
        address exchange = _deployExchange(usdc, ctf, cfg.safeFactoryAddress, cfg.deployedExchange);

        _configureExchange(exchange, cfg.operatorAddress, cfg.adminAddress, cfg.oracleAddress);

        // Persist addresses so they're readable by callers / tests.
        deployedUsdc = usdc;
        deployedCtf = ctf;
        deployedResolution = resolution;
        deployedExchange = exchange;

        console.log("");
        console.log("=== Deployment Summary ===");
        console.log("USDC:       ", usdc);
        console.log("CTF:        ", ctf);
        console.log("Resolution: ", resolution);
        console.log("Exchange:   ", exchange);
    }

    // ── Individual deployers ────────────────────────────────────────

    function _deployUsdc(address owner, address existing) internal returns (address) {
        if (_isDeployed(existing)) {
            console.log("[SKIP] TestUSDC already deployed at", existing);
            return existing;
        }

        TestUSDC usdc = new TestUSDC(owner);
        console.log("[DEPLOYED] TestUSDC at", address(usdc));
        return address(usdc);
    }

    function _deployCtf(address existing) internal returns (address) {
        if (_isDeployed(existing)) {
            console.log("[SKIP] ConditionalTokens already deployed at", existing);
            return existing;
        }

        MockConditionalTokens ctf = new MockConditionalTokens();
        console.log("[DEPLOYED] ConditionalTokens at", address(ctf));
        return address(ctf);
    }

    function _deployResolution(address owner, address ctfAddr, address existing, uint256 cooldownSecs)
        internal
        returns (address)
    {
        if (_isDeployed(existing)) {
            console.log("[SKIP] Resolution already deployed at", existing);
            return existing;
        }

        // Deployer serves as both owner and initial oracle.
        // Oracle role can be transferred later via setOracle().
        Resolution res = new Resolution(owner, owner, ctfAddr, cooldownSecs);
        console.log("[DEPLOYED] Resolution at", address(res));
        return address(res);
    }

    function _deployExchange(address usdc, address ctf, address safeFactory, address existing)
        internal
        returns (address)
    {
        if (_isDeployed(existing)) {
            console.log("[SKIP] ProphetCTFExchange already deployed at", existing);
            return existing;
        }

        require(safeFactory != address(0), "DeployConfig.safeFactoryAddress required");

        // _proxyFactory (3rd arg): address(0) — POLY_PROXY sig type is unused.
        // _safeFactory (4th arg): Poly SafeProxyFactory — used for POLY_GNOSIS_SAFE sig type.
        ProphetCTFExchange exchange = new ProphetCTFExchange(usdc, ctf, address(0), safeFactory);
        console.log("[DEPLOYED] ProphetCTFExchange at", address(exchange));

        _verifyProxyCreationCode(address(exchange), safeFactory);

        return address(exchange);
    }

    /// @dev H-03 deployment assertion: verifies that the hardcoded proxyCreationCode in
    ///      PolySafeLib matches the live bytecode from the Poly SafeProxyFactory. If they
    ///      diverge, POLY_GNOSIS_SAFE signature verification will silently fail for every user.
    ///      See: research/audit-findings-guide.md#h-03
    function _verifyProxyCreationCode(address exchange, address safeFactory) internal view {
        IPolySafeProxyFactory factory = IPolySafeProxyFactory(safeFactory);

        // What the exchange derives via PolySafeLib (hardcoded constant)
        address sentinel = address(0xDEAD);
        address exchangeDerived = ProphetCTFExchange(exchange).getSafeAddress(sentinel);

        // What the factory would produce via its live proxyCreationCode()
        address masterCopyAddr = factory.masterCopy();
        bytes memory creationCode = factory.proxyCreationCode();
        bytes memory bytecode = abi.encodePacked(creationCode, abi.encode(masterCopyAddr));
        bytes32 salt = keccak256(abi.encode(sentinel));
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), safeFactory, salt, keccak256(bytecode)));
        address factoryDerived = address(uint160(uint256(hash)));

        require(
            exchangeDerived == factoryDerived,
            "H-03: PolySafeLib proxyCreationCode diverges from factory -- update the constant before deploying"
        );
        console.log("[VERIFIED] PolySafeLib proxyCreationCode matches factory (H-03)");
    }

    // ── Post-deployment configuration ───────────────────────────────

    function _configureExchange(address exchange, address operatorAddr, address adminAddr, address oracleAddr)
        internal
    {
        ProphetCTFExchange ex = ProphetCTFExchange(exchange);

        if (operatorAddr != address(0) && !ex.isOperator(operatorAddr)) {
            ex.addOperator(operatorAddr);
            console.log("[CONFIG] Added operator:", operatorAddr);
        }

        if (adminAddr != address(0) && !ex.isAdmin(adminAddr)) {
            ex.addAdmin(adminAddr);
            console.log("[CONFIG] Added admin:", adminAddr);
        }

        if (oracleAddr != address(0) && ex.oracle() != oracleAddr) {
            ex.setOracle(oracleAddr);
            console.log("[CONFIG] Set oracle:", oracleAddr);
        }
    }

    // ── Helpers ─────────────────────────────────────────────────────

    /// @dev Reads an optional address from an environment variable. Returns address(0) if unset or empty.
    function _envAddress(string memory name) internal view returns (address) {
        return vm.envOr(name, address(0));
    }

    /// @dev Returns true if the address is non-zero and has deployed code.
    function _isDeployed(address addr) internal view returns (bool) {
        return addr != address(0) && addr.code.length > 0;
    }
}
