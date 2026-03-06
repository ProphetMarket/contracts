// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AddOperator} from "../script/AddOperator.s.sol";
import {ProphetCTFExchange} from "../src/ProphetCTFExchange.sol";
import {TestUSDC} from "../src/TestUSDC.sol";
import {MockConditionalTokens} from "../test/mocks/MockConditionalTokens.sol";
import {Deploy} from "../script/Deploy.s.sol";

contract AddOperatorTest is Test {
    AddOperator public script;
    ProphetCTFExchange public exchange;

    address public deployer;
    address public operator;

    function setUp() public {
        deployer = makeAddr("deployer");
        operator = makeAddr("operator");

        // Deploy a fresh exchange via the Deploy script.
        vm.setEnv("DEPLOYED_USDC", "");
        vm.setEnv("DEPLOYED_CTF", "");
        vm.setEnv("DEPLOYED_RESOLUTION", "");
        vm.setEnv("DEPLOYED_EXCHANGE", "");
        vm.setEnv("OPERATOR_ADDRESS", "");
        vm.setEnv("ADMIN_ADDRESS", "");

        Deploy deployScript = new Deploy();
        deployScript.run(deployer);
        exchange = ProphetCTFExchange(deployScript.deployedExchange());

        // Set env vars for AddOperator script.
        vm.setEnv("EXCHANGE_ADDRESS", vm.toString(address(exchange)));
        vm.setEnv("OPERATOR_ADDRESS", vm.toString(operator));

        script = new AddOperator();
    }

    // ── Registration ─────────────────────────────────────────────────

    function test_RegistersNewOperator() public {
        assertFalse(exchange.isOperator(operator), "operator should not be registered yet");

        script.run(deployer);

        assertTrue(exchange.isOperator(operator), "operator should be registered");
    }

    // ── Idempotency ──────────────────────────────────────────────────

    function test_IdempotentDoubleRun() public {
        script.run(deployer);
        assertTrue(exchange.isOperator(operator));

        // Second run should not revert.
        script.run(deployer);
        assertTrue(exchange.isOperator(operator));
    }

    // ── Validation ───────────────────────────────────────────────────

    function test_RevertsWithZeroExchangeAddress() public {
        vm.setEnv("EXCHANGE_ADDRESS", vm.toString(address(0)));

        vm.expectRevert(AddOperator.ExchangeAddressRequired.selector);
        script.run(deployer);
    }

    function test_RevertsWithZeroOperatorAddress() public {
        vm.setEnv("OPERATOR_ADDRESS", vm.toString(address(0)));

        vm.expectRevert(AddOperator.OperatorAddressRequired.selector);
        script.run(deployer);
    }
}
