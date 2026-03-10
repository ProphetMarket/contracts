// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Deploy, DeployConfig} from "../script/Deploy.s.sol";
import {TestUSDC} from "../src/TestUSDC.sol";
import {Resolution} from "../src/Resolution.sol";
import {ProphetCTFExchange} from "../src/ProphetCTFExchange.sol";
import {MockConditionalTokens} from "../test/mocks/MockConditionalTokens.sol";

contract DeployTest is Test {
    Deploy public deployScript;

    address public deployer;

    // Dummy Safe addresses used by tests that manually create a ProphetCTFExchange.
    // These don't need real bytecode — the exchange constructor stores them but
    // doesn't call them.
    address constant SAFE_FACTORY = address(0xFA);
    address constant SAFE_SINGLETON = address(0x5A);

    function setUp() public {
        deployer = makeAddr("deployer");
        deployScript = new Deploy();
    }

    /// @dev Returns a config for fresh deploy with dummy Safe addresses (no extra roles).
    function _emptyConfig() internal pure returns (DeployConfig memory) {
        return DeployConfig({
            deployedUsdc: address(0),
            deployedCtf: address(0),
            deployedResolution: address(0),
            deployedExchange: address(0),
            operatorAddress: address(0),
            adminAddress: address(0),
            safeFactoryAddress: SAFE_FACTORY,
            safeSingletonAddress: SAFE_SINGLETON
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
    }

    function test_SkipsAlreadyDeployedResolution() public {
        Resolution preRes = new Resolution(deployer, deployer);

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
            new ProphetCTFExchange(address(usdc), address(ctf), SAFE_FACTORY, SAFE_SINGLETON);
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
        Resolution res = new Resolution(deployer, deployer);
        ProphetCTFExchange exchange = new ProphetCTFExchange(address(usdc), address(ctf), SAFE_FACTORY, SAFE_SINGLETON);
        vm.stopPrank();

        DeployConfig memory cfg = DeployConfig({
            deployedUsdc: address(usdc),
            deployedCtf: address(ctf),
            deployedResolution: address(res),
            deployedExchange: address(exchange),
            operatorAddress: address(0),
            adminAddress: address(0),
            safeFactoryAddress: SAFE_FACTORY,
            safeSingletonAddress: SAFE_SINGLETON
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
}
