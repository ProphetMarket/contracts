// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AddOperator} from "../script/AddOperator.s.sol";
import {ProphetCTFExchange} from "../src/ProphetCTFExchange.sol";
import {Deploy, DeployConfig} from "../script/Deploy.s.sol";

contract AddOperatorTest is Test {
    AddOperator public script;
    ProphetCTFExchange public exchange;

    address public deployer;
    address public operator;

    function setUp() public {
        deployer = makeAddr("deployer");
        operator = makeAddr("operator");

        // Deploy a fresh exchange via the Deploy script (no env vars needed).
        Deploy deployScript = new Deploy();
        deployScript.run(
            deployer,
            DeployConfig({
                deployedUsdc: address(0),
                deployedCtf: address(0),
                deployedResolution: address(0),
                deployedExchange: address(0),
                operatorAddress: address(0),
                adminAddress: address(0),
                safeFactoryAddress: address(0xFA),
                safeSingletonAddress: address(0x5A)
            })
        );
        exchange = ProphetCTFExchange(deployScript.deployedExchange());

        script = new AddOperator();
    }

    // ── Registration ─────────────────────────────────────────────────

    function test_RegistersNewOperator() public {
        assertFalse(exchange.isOperator(operator), "operator should not be registered yet");

        script.run(deployer, address(exchange), operator);

        assertTrue(exchange.isOperator(operator), "operator should be registered");
    }

    // ── Idempotency ──────────────────────────────────────────────────

    function test_IdempotentDoubleRun() public {
        script.run(deployer, address(exchange), operator);
        assertTrue(exchange.isOperator(operator));

        // Second run should not revert.
        script.run(deployer, address(exchange), operator);
        assertTrue(exchange.isOperator(operator));
    }

    // ── Validation ───────────────────────────────────────────────────

    function test_RevertsWithZeroExchangeAddress() public {
        vm.expectRevert(AddOperator.ExchangeAddressRequired.selector);
        script.run(deployer, address(0), operator);
    }

    function test_RevertsWithZeroOperatorAddress() public {
        vm.expectRevert(AddOperator.OperatorAddressRequired.selector);
        script.run(deployer, address(exchange), address(0));
    }
}
