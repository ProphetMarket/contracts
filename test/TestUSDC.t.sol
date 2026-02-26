// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TestUSDC} from "../src/TestUSDC.sol";

contract TestUSDCTest is Test {
    TestUSDC public token;

    address public owner = address(0x1);
    address public alice = address(0x2);
    address public bob = address(0x3);

    uint256 constant FAUCET_MAX = 100_000 * 10 ** 6;
    uint256 constant COOLDOWN = 24 hours;

    function setUp() public {
        token = new TestUSDC(owner);
    }

    // ── Deployment ──────────────────────────────────────────────────

    function test_Name() public view {
        assertEq(token.name(), "Test USD Coin");
    }

    function test_Symbol() public view {
        assertEq(token.symbol(), "USDC");
    }

    function test_Decimals() public view {
        assertEq(token.decimals(), 6);
    }

    function test_Owner() public view {
        assertEq(token.owner(), owner);
    }

    function test_InitialSupplyIsZero() public view {
        assertEq(token.totalSupply(), 0);
    }

    // ── Mainnet guard ───────────────────────────────────────────────

    function test_RevertsOnMainnetDeployment() public {
        vm.chainId(137);
        vm.expectRevert(TestUSDC.MainnetDeploymentBlocked.selector);
        new TestUSDC(owner);
    }

    function test_DeploysOnNonMainnetChain() public {
        vm.chainId(80002); // Amoy testnet
        TestUSDC amoyToken = new TestUSDC(owner);
        assertEq(amoyToken.decimals(), 6);
    }

    // ── Owner mint ──────────────────────────────────────────────────

    function test_OwnerCanMint() public {
        vm.prank(owner);
        token.mint(alice, 1_000 * 10 ** 6);
        assertEq(token.balanceOf(alice), 1_000 * 10 ** 6);
    }

    function test_OwnerCanMintLargeAmount() public {
        uint256 amount = 1_000_000_000 * 10 ** 6; // 1 billion USDC
        vm.prank(owner);
        token.mint(alice, amount);
        assertEq(token.balanceOf(alice), amount);
    }

    function test_NonOwnerCannotMint() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        token.mint(alice, 1_000 * 10 ** 6);
    }

    // ── Faucet ──────────────────────────────────────────────────────

    function test_FaucetMintsTokens() public {
        vm.prank(alice);
        token.faucet(alice, 50_000 * 10 ** 6);
        assertEq(token.balanceOf(alice), 50_000 * 10 ** 6);
    }

    function test_FaucetMintsToAnotherAddress() public {
        vm.prank(alice);
        token.faucet(bob, 10_000 * 10 ** 6);
        assertEq(token.balanceOf(bob), 10_000 * 10 ** 6);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_FaucetMaxAmount() public {
        vm.prank(alice);
        token.faucet(alice, FAUCET_MAX);
        assertEq(token.balanceOf(alice), FAUCET_MAX);
    }

    function test_FaucetRevertsOverMax() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TestUSDC.FaucetAmountExceedsMax.selector, FAUCET_MAX + 1, FAUCET_MAX));
        token.faucet(alice, FAUCET_MAX + 1);
    }

    function test_FaucetCooldownBlocksSecondCall() public {
        vm.startPrank(alice);

        token.faucet(alice, 1_000 * 10 ** 6);

        uint256 availableAt = block.timestamp + COOLDOWN;
        vm.expectRevert(abi.encodeWithSelector(TestUSDC.FaucetCooldownActive.selector, availableAt));
        token.faucet(alice, 1_000 * 10 ** 6);

        vm.stopPrank();
    }

    function test_FaucetWorksAfterCooldown() public {
        vm.startPrank(alice);

        token.faucet(alice, 1_000 * 10 ** 6);

        vm.warp(block.timestamp + COOLDOWN);
        token.faucet(alice, 2_000 * 10 ** 6);

        assertEq(token.balanceOf(alice), 3_000 * 10 ** 6);

        vm.stopPrank();
    }

    function test_FaucetCooldownIsPerCaller() public {
        vm.prank(alice);
        token.faucet(alice, 1_000 * 10 ** 6);

        // Bob can faucet immediately (different caller)
        vm.prank(bob);
        token.faucet(bob, 1_000 * 10 ** 6);

        assertEq(token.balanceOf(alice), 1_000 * 10 ** 6);
        assertEq(token.balanceOf(bob), 1_000 * 10 ** 6);
    }

    function test_FaucetUpdatesLastFaucetTime() public {
        uint256 ts = 1_700_000_000;
        vm.warp(ts);

        vm.prank(alice);
        token.faucet(alice, 1_000 * 10 ** 6);

        assertEq(token.lastFaucetTime(alice), ts);
    }

    // ── ERC-20 transfers ────────────────────────────────────────────

    function test_Transfer() public {
        vm.prank(owner);
        token.mint(alice, 1_000 * 10 ** 6);

        vm.prank(alice);
        bool sent = token.transfer(bob, 400 * 10 ** 6);
        assertTrue(sent);

        assertEq(token.balanceOf(alice), 600 * 10 ** 6);
        assertEq(token.balanceOf(bob), 400 * 10 ** 6);
    }

    function test_Approve_TransferFrom() public {
        vm.prank(owner);
        token.mint(alice, 1_000 * 10 ** 6);

        vm.prank(alice);
        token.approve(bob, 500 * 10 ** 6);

        vm.prank(bob);
        bool sent = token.transferFrom(alice, bob, 500 * 10 ** 6);
        assertTrue(sent);

        assertEq(token.balanceOf(alice), 500 * 10 ** 6);
        assertEq(token.balanceOf(bob), 500 * 10 ** 6);
    }

    // ── Fuzz ────────────────────────────────────────────────────────

    function testFuzz_FaucetAmountUpToMax(uint256 amount) public {
        amount = bound(amount, 0, FAUCET_MAX);

        vm.prank(alice);
        token.faucet(alice, amount);

        assertEq(token.balanceOf(alice), amount);
    }
}
