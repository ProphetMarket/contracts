// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Deploy, DeployConfig} from "../script/Deploy.s.sol";
import {TestUSDC} from "../src/TestUSDC.sol";
import {Resolution} from "../src/Resolution.sol";
import {ProphetCTFExchange} from "../src/ProphetCTFExchange.sol";
import {MockConditionalTokens} from "../test/mocks/MockConditionalTokens.sol";
import {MockPolySafeFactory} from "../test/mocks/MockPolySafeFactory.sol";

contract DeployTest is Test {
    Deploy public deployScript;
    MockPolySafeFactory public safeFactory;

    address public deployer;

    /// @dev A known masterCopy address for the mock factory.
    address constant MOCK_SINGLETON = address(0x5afe5afE5afE5afE5afE5aFe5aFe5Afe5Afe5AfE);

    function setUp() public {
        deployer = makeAddr("deployer");
        deployScript = new Deploy();
        safeFactory = new MockPolySafeFactory(MOCK_SINGLETON);
    }

    /// @dev Returns a config for fresh deploy with MockPolySafeFactory. The oracle and
    ///      operator default to the deployer because ORACLE_ADDRESS and OPERATOR_ADDRESS
    ///      are required prerequisites of the deploy script — tests that need different
    ///      values override the relevant field locally.
    function _emptyConfig() internal view returns (DeployConfig memory) {
        return DeployConfig({
            deployedUsdc: address(0),
            deployedCtf: address(0),
            deployedResolution: address(0),
            deployedExchange: address(0),
            operatorAddress: deployer,
            adminAddress: address(0),
            oracleAddress: deployer,
            safeFactoryAddress: address(safeFactory),
            cooldownPeriod: 12 hours
        });
    }

    // ── Fresh deployment ────────────────────────────────────────────

    function test_DeploysAllFourContracts() public {
        deployScript.run(deployer, _emptyConfig());

        assertTrue(deployScript.deployedUsdc() != address(0), "USDC not deployed");
        assertTrue(deployScript.deployedCtf() != address(0), "CTF not deployed");
        assertTrue(deployScript.deployedResolution() != address(0), "Resolution not deployed");
        assertTrue(deployScript.deployedExchange() != address(0), "Exchange not deployed");
    }

    function test_DeployedUsdcHasCorrectOwner() public {
        deployScript.run(deployer, _emptyConfig());

        TestUSDC usdc = TestUSDC(deployScript.deployedUsdc());
        assertEq(usdc.owner(), deployer);
    }

    function test_DeployedResolutionHasCorrectOwnerAndOracle() public {
        deployScript.run(deployer, _emptyConfig());

        Resolution res = Resolution(deployScript.deployedResolution());
        assertEq(res.owner(), deployer);
        assertEq(res.oracle(), deployer);
        assertEq(address(res.ctf()), deployScript.deployedCtf());
        assertEq(res.cooldownPeriod(), 12 hours);
    }

    function test_DeployedExchangeHasDeployerAsAdminAndOperator() public {
        deployScript.run(deployer, _emptyConfig());

        ProphetCTFExchange exchange = ProphetCTFExchange(deployScript.deployedExchange());
        assertTrue(exchange.isAdmin(deployer));
        assertTrue(exchange.isOperator(deployer));
    }

    function test_ExchangeApprovesUsdcToCtf() public {
        deployScript.run(deployer, _emptyConfig());

        TestUSDC usdc = TestUSDC(deployScript.deployedUsdc());
        uint256 allowance = usdc.allowance(deployScript.deployedExchange(), deployScript.deployedCtf());
        assertEq(allowance, type(uint256).max);
    }

    // ── Mainnet guard ───────────────────────────────────────────────

    function test_RevertsOnMainnet() public {
        vm.chainId(137);
        vm.expectRevert(Deploy.MainnetNotSupported.selector);
        deployScript.run();
    }

    // ── Idempotency: skip already-deployed contracts ────────────────

    function test_SkipsAlreadyDeployedUsdc() public {
        TestUSDC preUsdc = new TestUSDC(deployer);

        DeployConfig memory cfg = _emptyConfig();
        cfg.deployedUsdc = address(preUsdc);

        deployScript.run(deployer, cfg);

        assertEq(preUsdc.owner(), deployer);
    }

    function test_SkipsAlreadyDeployedCtf() public {
        MockConditionalTokens preCtf = new MockConditionalTokens();

        DeployConfig memory cfg = _emptyConfig();
        cfg.deployedCtf = address(preCtf);

        deployScript.run(deployer, cfg);

        assertEq(deployScript.deployedCtf(), address(preCtf));
    }

    function test_SkipsAlreadyDeployedResolution() public {
        MockConditionalTokens preCtf = new MockConditionalTokens();
        Resolution preRes = new Resolution(deployer, deployer, address(preCtf), 12 hours);

        DeployConfig memory cfg = _emptyConfig();
        cfg.deployedResolution = address(preRes);

        deployScript.run(deployer, cfg);

        assertEq(preRes.owner(), deployer);
    }

    function test_SkipsAlreadyDeployedExchange() public {
        vm.startPrank(deployer);
        TestUSDC usdc = new TestUSDC(deployer);
        MockConditionalTokens ctf = new MockConditionalTokens();
        ProphetCTFExchange preExchange =
            new ProphetCTFExchange(address(usdc), address(ctf), address(0), address(safeFactory));
        vm.stopPrank();

        DeployConfig memory cfg = _emptyConfig();
        cfg.deployedUsdc = address(usdc);
        cfg.deployedCtf = address(ctf);
        cfg.deployedExchange = address(preExchange);

        deployScript.run(deployer, cfg);

        assertTrue(preExchange.isAdmin(deployer));
    }

    function test_SkipsAllWhenFullyDeployed() public {
        vm.startPrank(deployer);
        TestUSDC usdc = new TestUSDC(deployer);
        MockConditionalTokens ctf = new MockConditionalTokens();
        Resolution res = new Resolution(deployer, deployer, address(ctf), 12 hours);
        ProphetCTFExchange exchange =
            new ProphetCTFExchange(address(usdc), address(ctf), address(0), address(safeFactory));
        vm.stopPrank();

        DeployConfig memory cfg = DeployConfig({
            deployedUsdc: address(usdc),
            deployedCtf: address(ctf),
            deployedResolution: address(res),
            deployedExchange: address(exchange),
            operatorAddress: deployer,
            adminAddress: address(0),
            oracleAddress: deployer,
            safeFactoryAddress: address(safeFactory),
            cooldownPeriod: 12 hours
        });

        deployScript.run(deployer, cfg);

        assertEq(deployScript.deployedUsdc(), address(usdc));
        assertEq(deployScript.deployedCtf(), address(ctf));
        assertEq(deployScript.deployedResolution(), address(res));
        assertEq(deployScript.deployedExchange(), address(exchange));
    }

    // ── Operator and admin configuration ────────────────────────────

    function test_RegistersSeparateOperator() public {
        address operator = address(0xBEEF);

        DeployConfig memory cfg = _emptyConfig();
        cfg.operatorAddress = operator;

        deployScript.run(deployer, cfg);

        ProphetCTFExchange exchange = ProphetCTFExchange(deployScript.deployedExchange());
        assertTrue(exchange.isOperator(operator));
    }

    function test_RegistersSeparateAdmin() public {
        address admin = address(0xCAFE);

        DeployConfig memory cfg = _emptyConfig();
        cfg.adminAddress = admin;

        deployScript.run(deployer, cfg);

        ProphetCTFExchange exchange = ProphetCTFExchange(deployScript.deployedExchange());
        assertTrue(exchange.isAdmin(admin));
    }

    function test_RegistersBothOperatorAndAdmin() public {
        address operator = address(0xBEEF);
        address admin = address(0xCAFE);

        DeployConfig memory cfg = _emptyConfig();
        cfg.operatorAddress = operator;
        cfg.adminAddress = admin;

        deployScript.run(deployer, cfg);

        ProphetCTFExchange exchange = ProphetCTFExchange(deployScript.deployedExchange());
        assertTrue(exchange.isOperator(operator));
        assertTrue(exchange.isAdmin(admin));
    }

    function test_SetsExchangeOracle() public {
        address oracleEoa = address(0x0BAD);

        DeployConfig memory cfg = _emptyConfig();
        cfg.oracleAddress = oracleEoa;

        deployScript.run(deployer, cfg);

        ProphetCTFExchange exchange = ProphetCTFExchange(deployScript.deployedExchange());
        assertEq(exchange.oracle(), oracleEoa);
    }

    /// @notice ORACLE_ADDRESS is a required prerequisite of the deploy script. Running
    ///         with oracleAddress unset must abort up front, not produce an exchange
    ///         with an empty oracle slot.
    function test_RevertsWhenOracleAddressUnset() public {
        DeployConfig memory cfg = _emptyConfig();
        cfg.oracleAddress = address(0);

        vm.expectRevert(bytes("DeployConfig.oracleAddress required"));
        deployScript.run(deployer, cfg);
    }

    /// @notice OPERATOR_ADDRESS is a required prerequisite. Production deploys must
    ///         install a separate operator key alongside the deployer; the script
    ///         aborts up front if the env var is unset.
    function test_RevertsWhenOperatorAddressUnset() public {
        DeployConfig memory cfg = _emptyConfig();
        cfg.operatorAddress = address(0);

        vm.expectRevert(bytes("DeployConfig.operatorAddress required"));
        deployScript.run(deployer, cfg);
    }

    /// @notice SAFE_FACTORY_ADDRESS is required when the script will deploy a fresh
    ///         exchange. The check is hoisted to the top of _deploy so the script
    ///         aborts before deploying USDC / CTF / Resolution.
    function test_RevertsWhenSafeFactoryUnsetForFreshDeploy() public {
        DeployConfig memory cfg = _emptyConfig();
        cfg.safeFactoryAddress = address(0);

        vm.expectRevert(bytes("DeployConfig.safeFactoryAddress required"));
        deployScript.run(deployer, cfg);
    }

    /// @notice Re-runs against an already-deployed exchange must not require
    ///         safeFactoryAddress — the existing exchange already has it baked in.
    function test_AllowsUnsetSafeFactoryWhenExchangeAlreadyDeployed() public {
        vm.startPrank(deployer);
        TestUSDC usdc = new TestUSDC(deployer);
        MockConditionalTokens ctf = new MockConditionalTokens();
        ProphetCTFExchange preExchange =
            new ProphetCTFExchange(address(usdc), address(ctf), address(0), address(safeFactory));
        vm.stopPrank();

        DeployConfig memory cfg = _emptyConfig();
        cfg.deployedUsdc = address(usdc);
        cfg.deployedCtf = address(ctf);
        cfg.deployedExchange = address(preExchange);
        cfg.safeFactoryAddress = address(0);

        deployScript.run(deployer, cfg);

        assertEq(deployScript.deployedExchange(), address(preExchange));
    }

    /// @notice Fresh deploy must wire the exchange to the freshly-deployed Resolution.
    ///         Without this, the on-chain CTF-oracle binding in _validateTokenCondition
    ///         can never succeed because resolution() stays at address(0).
    function test_SetsExchangeResolution() public {
        deployScript.run(deployer, _emptyConfig());

        ProphetCTFExchange exchange = ProphetCTFExchange(deployScript.deployedExchange());
        assertEq(exchange.resolution(), deployScript.deployedResolution());
        assertTrue(exchange.resolution() != address(0));
    }

    /// @notice Re-running the script against a pre-deployed exchange whose resolution()
    ///         is still zero must wire it during the configure step. This covers the
    ///         post-hoc remediation case for an exchange that was deployed before the
    ///         setResolution wiring landed in the script.
    function test_SetsExchangeResolution_onPreDeployedExchange() public {
        vm.startPrank(deployer);
        TestUSDC usdc = new TestUSDC(deployer);
        MockConditionalTokens ctf = new MockConditionalTokens();
        ProphetCTFExchange preExchange =
            new ProphetCTFExchange(address(usdc), address(ctf), address(0), address(safeFactory));
        vm.stopPrank();

        assertEq(preExchange.resolution(), address(0));

        DeployConfig memory cfg = _emptyConfig();
        cfg.deployedUsdc = address(usdc);
        cfg.deployedCtf = address(ctf);
        cfg.deployedExchange = address(preExchange);

        deployScript.run(deployer, cfg);

        assertEq(preExchange.resolution(), deployScript.deployedResolution());
    }

    // ── Safe address derivation ──────────────────────────────────────

    function test_ExchangeGetSafeAddressReturnsCorrectAddress() public {
        deployScript.run(deployer, _emptyConfig());

        ProphetCTFExchange exchange = ProphetCTFExchange(deployScript.deployedExchange());

        address eoa1 = makeAddr("eoa1");
        address eoa2 = makeAddr("eoa2");

        address safe1 = exchange.getSafeAddress(eoa1);
        address safe2 = exchange.getSafeAddress(eoa2);

        // Derived addresses are non-zero
        assertTrue(safe1 != address(0), "Safe address for eoa1 should be non-zero");
        assertTrue(safe2 != address(0), "Safe address for eoa2 should be non-zero");

        // Different EOAs produce different Safe addresses
        assertTrue(safe1 != safe2, "Different EOAs should produce different Safe addresses");

        // Same EOA always produces the same Safe address (deterministic)
        assertEq(exchange.getSafeAddress(eoa1), safe1, "getSafeAddress should be deterministic");
    }

    function test_ExchangeSafeFactoryIsSet() public {
        deployScript.run(deployer, _emptyConfig());

        ProphetCTFExchange exchange = ProphetCTFExchange(deployScript.deployedExchange());
        assertEq(exchange.getSafeFactory(), address(safeFactory), "safeFactory should be the Poly factory");
    }

    function test_ExchangeProxyFactoryIsZero() public {
        deployScript.run(deployer, _emptyConfig());

        ProphetCTFExchange exchange = ProphetCTFExchange(deployScript.deployedExchange());
        assertEq(exchange.getProxyFactory(), address(0), "proxyFactory should be address(0)");
    }
}
