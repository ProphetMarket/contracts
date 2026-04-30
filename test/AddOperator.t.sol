// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {AddOperator} from "../script/AddOperator.s.sol";
import {ProphetCTFExchange} from "../src/ProphetCTFExchange.sol";
import {Deploy, DeployConfig} from "../script/Deploy.s.sol";
import {MockPolySafeFactory} from "../test/mocks/MockPolySafeFactory.sol";

contract AddOperatorTest is Test {
    AddOperator public script;
    ProphetCTFExchange public exchange;

    address public deployer;
    address public operator;

    function setUp() public {
        deployer = makeAddr("deployer");
        operator = makeAddr("operator");

        MockPolySafeFactory safeFactory = new MockPolySafeFactory(address(0x5afe5afE5afE5afE5afE5aFe5aFe5Afe5Afe5AfE));

        // Deploy a fresh exchange via the Deploy script. ORACLE_ADDRESS and
        // OPERATOR_ADDRESS are required prerequisites of the deploy, so we wire the
        // deployer in for both — this test exercises post-deploy operator rotation, not
        // initial wiring.
        Deploy deployScript = new Deploy();
        deployScript.run(
            deployer,
            DeployConfig({
                deployedUsdc: address(0),
                deployedCtf: address(0),
                deployedResolution: address(0),
                deployedExchange: address(0),
                operatorAddress: deployer,
                adminAddress: address(0),
                oracleAddress: deployer,
                safeFactoryAddress: address(safeFactory),
                cooldownPeriod: 12 hours
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
