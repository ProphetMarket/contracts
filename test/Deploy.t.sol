// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {TestUSDC} from "../src/TestUSDC.sol";
import {Resolution} from "../src/Resolution.sol";
import {ProphetCTFExchange} from "../src/ProphetCTFExchange.sol";
import {MockConditionalTokens} from "../test/mocks/MockConditionalTokens.sol";

contract DeployTest is Test {
    Deploy public deployScript;

    address public deployer;

    function setUp() public {
        deployer = makeAddr("deployer");
        // Clear all optional env vars to prevent state leaking between tests
        vm.setEnv("DEPLOYED_USDC", "");
        vm.setEnv("DEPLOYED_CTF", "");
        vm.setEnv("DEPLOYED_RESOLUTION", "");
        vm.setEnv("DEPLOYED_EXCHANGE", "");
        vm.setEnv("OPERATOR_ADDRESS", "");
        vm.setEnv("ADMIN_ADDRESS", "");
        deployScript = new Deploy();
    }

    // ── Fresh deployment ────────────────────────────────────────────

    function test_DeploysAllFourContracts() public {
        deployScript.run(deployer);

        assertTrue(deployScript.deployedUsdc() != address(0), "USDC not deployed");
        assertTrue(deployScript.deployedCtf() != address(0), "CTF not deployed");
        assertTrue(deployScript.deployedResolution() != address(0), "Resolution not deployed");
        assertTrue(deployScript.deployedExchange() != address(0), "Exchange not deployed");
    }

    function test_DeployedUsdcHasCorrectOwner() public {
        deployScript.run(deployer);

        TestUSDC usdc = TestUSDC(deployScript.deployedUsdc());
        assertEq(usdc.owner(), deployer);
    }

    function test_DeployedResolutionHasCorrectOwnerAndOracle() public {
        deployScript.run(deployer);

        Resolution res = Resolution(deployScript.deployedResolution());
        assertEq(res.owner(), deployer);
        assertEq(res.oracle(), deployer);
    }

    function test_DeployedExchangeHasDeployerAsAdminAndOperator() public {
        deployScript.run(deployer);

        ProphetCTFExchange exchange = ProphetCTFExchange(deployScript.deployedExchange());
        assertTrue(exchange.isAdmin(deployer));
        assertTrue(exchange.isOperator(deployer));
    }

    function test_ExchangeApprovesUsdcToCtf() public {
        deployScript.run(deployer);

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
    // These tests verify the script completes successfully when pre-deployed
    // addresses are provided. The script logs [SKIP] for each recognized address.

    function test_SkipsAlreadyDeployedUsdc() public {
        TestUSDC preUsdc = new TestUSDC(deployer);
        vm.setEnv("DEPLOYED_USDC", vm.toString(address(preUsdc)));

        deployScript.run(deployer);

        // Pre-deployed USDC should still be intact
        assertEq(preUsdc.owner(), deployer);
    }

    function test_SkipsAlreadyDeployedCtf() public {
        MockConditionalTokens preCtf = new MockConditionalTokens();
        vm.setEnv("DEPLOYED_CTF", vm.toString(address(preCtf)));

        deployScript.run(deployer);
    }

    function test_SkipsAlreadyDeployedResolution() public {
        Resolution preRes = new Resolution(deployer, deployer);
        vm.setEnv("DEPLOYED_RESOLUTION", vm.toString(address(preRes)));

        deployScript.run(deployer);

        assertEq(preRes.owner(), deployer);
    }

    function test_SkipsAlreadyDeployedExchange() public {
        vm.startPrank(deployer);
        TestUSDC usdc = new TestUSDC(deployer);
        MockConditionalTokens ctf = new MockConditionalTokens();
        ProphetCTFExchange preExchange = new ProphetCTFExchange(
            address(usdc), address(ctf), deployScript.SAFE_PROXY_FACTORY(), deployScript.SAFE_L2_SINGLETON()
        );
        vm.stopPrank();

        vm.setEnv("DEPLOYED_USDC", vm.toString(address(usdc)));
        vm.setEnv("DEPLOYED_CTF", vm.toString(address(ctf)));
        vm.setEnv("DEPLOYED_EXCHANGE", vm.toString(address(preExchange)));

        deployScript.run(deployer);

        assertTrue(preExchange.isAdmin(deployer));
    }

    function test_SkipsAllWhenFullyDeployed() public {
        vm.startPrank(deployer);
        TestUSDC usdc = new TestUSDC(deployer);
        MockConditionalTokens ctf = new MockConditionalTokens();
        Resolution res = new Resolution(deployer, deployer);
        ProphetCTFExchange exchange = new ProphetCTFExchange(
            address(usdc), address(ctf), deployScript.SAFE_PROXY_FACTORY(), deployScript.SAFE_L2_SINGLETON()
        );
        vm.stopPrank();

        vm.setEnv("DEPLOYED_USDC", vm.toString(address(usdc)));
        vm.setEnv("DEPLOYED_CTF", vm.toString(address(ctf)));
        vm.setEnv("DEPLOYED_RESOLUTION", vm.toString(address(res)));
        vm.setEnv("DEPLOYED_EXCHANGE", vm.toString(address(exchange)));

        deployScript.run(deployer);

        // All four should use the pre-deployed addresses
        assertEq(deployScript.deployedUsdc(), address(usdc));
        assertEq(deployScript.deployedCtf(), address(ctf));
        assertEq(deployScript.deployedResolution(), address(res));
        assertEq(deployScript.deployedExchange(), address(exchange));
    }

    // ── Operator and admin configuration ────────────────────────────

    function test_RegistersSeparateOperator() public {
        address operator = address(0xBEEF);
        vm.setEnv("OPERATOR_ADDRESS", vm.toString(operator));

        deployScript.run(deployer);

        ProphetCTFExchange exchange = ProphetCTFExchange(deployScript.deployedExchange());
        assertTrue(exchange.isOperator(operator));
    }

    function test_RegistersSeparateAdmin() public {
        address admin = address(0xCAFE);
        vm.setEnv("ADMIN_ADDRESS", vm.toString(admin));

        deployScript.run(deployer);

        ProphetCTFExchange exchange = ProphetCTFExchange(deployScript.deployedExchange());
        assertTrue(exchange.isAdmin(admin));
    }

    function test_RegistersBothOperatorAndAdmin() public {
        address operator = address(0xBEEF);
        address admin = address(0xCAFE);
        vm.setEnv("OPERATOR_ADDRESS", vm.toString(operator));
        vm.setEnv("ADMIN_ADDRESS", vm.toString(admin));

        deployScript.run(deployer);

        ProphetCTFExchange exchange = ProphetCTFExchange(deployScript.deployedExchange());
        assertTrue(exchange.isOperator(operator));
        assertTrue(exchange.isAdmin(admin));
    }

    // ── Constants ───────────────────────────────────────────────────

    function test_SafeFactoryAddressesAreCorrect() public view {
        assertEq(deployScript.SAFE_PROXY_FACTORY(), 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67);
        assertEq(deployScript.SAFE_L2_SINGLETON(), 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762);
    }
}
