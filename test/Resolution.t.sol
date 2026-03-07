// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Resolution} from "../src/Resolution.sol";

contract ResolutionTest is Test {
    Resolution public resolution;

    address public owner = address(0x1);
    address public oracle = address(0x2);
    address public alice = address(0x3);
    address public bob = address(0x4);

    bytes32 constant CONDITION_A = keccak256("market-A");
    bytes32 constant CONDITION_B = keccak256("market-B");
    string constant SAMPLE_CID = "QmTestCID1234567890abcdefghijklmnopqrstuvwxyz";

    function setUp() public {
        resolution = new Resolution(owner, oracle);
    }

    // ── Helpers ──────────────────────────────────────────────────────

    function _yesWins() internal pure returns (uint256[] memory) {
        uint256[] memory p = new uint256[](2);
        p[0] = 1;
        p[1] = 0;
        return p;
    }

    function _noWins() internal pure returns (uint256[] memory) {
        uint256[] memory p = new uint256[](2);
        p[0] = 0;
        p[1] = 1;
        return p;
    }

    // ── Deployment ───────────────────────────────────────────────────

    function test_Owner() public view {
        assertEq(resolution.owner(), owner);
    }

    function test_Oracle() public view {
        assertEq(resolution.oracle(), oracle);
    }

    function test_ConstructorEmitsOracleTransferred() public {
        vm.expectEmit(true, true, false, true);
        emit Resolution.OracleTransferred(address(0), oracle);
        new Resolution(owner, oracle);
    }

    function test_ConstructorRevertsZeroOracle() public {
        vm.expectRevert(Resolution.ZeroAddress.selector);
        new Resolution(owner, address(0));
    }

    // ── reportPayouts ────────────────────────────────────────────────

    function test_ReportPayoutsYesWins() public {
        vm.prank(oracle);
        resolution.reportPayouts(CONDITION_A, _yesWins(), SAMPLE_CID);

        assertTrue(resolution.isReported(CONDITION_A));
        uint256[] memory p = resolution.getPayouts(CONDITION_A);
        assertEq(p.length, 2);
        assertEq(p[0], 1);
        assertEq(p[1], 0);
    }

    function test_ReportPayoutsNoWins() public {
        vm.prank(oracle);
        resolution.reportPayouts(CONDITION_A, _noWins(), SAMPLE_CID);

        assertTrue(resolution.isReported(CONDITION_A));
        uint256[] memory p = resolution.getPayouts(CONDITION_A);
        assertEq(p[0], 0);
        assertEq(p[1], 1);
    }

    function test_ReportPayoutsEmitsEvent() public {
        vm.prank(oracle);
        vm.expectEmit(true, false, false, true);
        emit Resolution.PayoutsReported(CONDITION_A, _yesWins(), SAMPLE_CID);
        resolution.reportPayouts(CONDITION_A, _yesWins(), SAMPLE_CID);
    }

    function test_ReportPayoutsStoresCid() public {
        vm.prank(oracle);
        resolution.reportPayouts(CONDITION_A, _yesWins(), SAMPLE_CID);

        assertEq(resolution.getIpfsCid(CONDITION_A), SAMPLE_CID);
    }

    function test_ReportPayoutsEmptyCidAllowed() public {
        vm.prank(oracle);
        resolution.reportPayouts(CONDITION_A, _yesWins(), "");

        assertTrue(resolution.isReported(CONDITION_A));
        assertEq(resolution.getIpfsCid(CONDITION_A), "");
    }

    function test_GetIpfsCidEmptyForUnknown() public view {
        assertEq(resolution.getIpfsCid(CONDITION_A), "");
    }

    function test_ReportPayoutsMultipleConditions() public {
        vm.startPrank(oracle);
        resolution.reportPayouts(CONDITION_A, _yesWins(), SAMPLE_CID);
        resolution.reportPayouts(CONDITION_B, _noWins(), "");
        vm.stopPrank();

        assertTrue(resolution.isReported(CONDITION_A));
        assertTrue(resolution.isReported(CONDITION_B));

        uint256[] memory pA = resolution.getPayouts(CONDITION_A);
        assertEq(pA[0], 1);

        uint256[] memory pB = resolution.getPayouts(CONDITION_B);
        assertEq(pB[0], 0);

        assertEq(resolution.getIpfsCid(CONDITION_A), SAMPLE_CID);
        assertEq(resolution.getIpfsCid(CONDITION_B), "");
    }

    function test_ReportPayoutsRevertsForNonOracle() public {
        vm.prank(alice);
        vm.expectRevert(Resolution.Unauthorized.selector);
        resolution.reportPayouts(CONDITION_A, _yesWins(), SAMPLE_CID);
    }

    function test_ReportPayoutsRevertsForOwnerNotOracle() public {
        vm.prank(owner);
        vm.expectRevert(Resolution.Unauthorized.selector);
        resolution.reportPayouts(CONDITION_A, _yesWins(), SAMPLE_CID);
    }

    function test_ReportPayoutsRevertsAlreadyReported() public {
        vm.startPrank(oracle);
        resolution.reportPayouts(CONDITION_A, _yesWins(), SAMPLE_CID);

        vm.expectRevert(abi.encodeWithSelector(Resolution.AlreadyReported.selector, CONDITION_A));
        resolution.reportPayouts(CONDITION_A, _noWins(), SAMPLE_CID);
        vm.stopPrank();
    }

    function test_ReportPayoutsRevertsEmptyArray() public {
        uint256[] memory empty = new uint256[](0);

        vm.prank(oracle);
        vm.expectRevert(abi.encodeWithSelector(Resolution.InvalidPayoutsLength.selector, 0));
        resolution.reportPayouts(CONDITION_A, empty, SAMPLE_CID);
    }

    function test_ReportPayoutsRevertsLengthOne() public {
        uint256[] memory one = new uint256[](1);
        one[0] = 1;

        vm.prank(oracle);
        vm.expectRevert(abi.encodeWithSelector(Resolution.InvalidPayoutsLength.selector, 1));
        resolution.reportPayouts(CONDITION_A, one, SAMPLE_CID);
    }

    function test_ReportPayoutsRevertsLengthThree() public {
        uint256[] memory three = new uint256[](3);
        three[0] = 1;

        vm.prank(oracle);
        vm.expectRevert(abi.encodeWithSelector(Resolution.InvalidPayoutsLength.selector, 3));
        resolution.reportPayouts(CONDITION_A, three, SAMPLE_CID);
    }

    function test_ReportPayoutsRevertsBothZero() public {
        uint256[] memory p = new uint256[](2);

        vm.prank(oracle);
        vm.expectRevert(Resolution.InvalidPayoutValues.selector);
        resolution.reportPayouts(CONDITION_A, p, SAMPLE_CID);
    }

    function test_ReportPayoutsRevertsBothOne() public {
        uint256[] memory p = new uint256[](2);
        p[0] = 1;
        p[1] = 1;

        vm.prank(oracle);
        vm.expectRevert(Resolution.InvalidPayoutValues.selector);
        resolution.reportPayouts(CONDITION_A, p, SAMPLE_CID);
    }

    function test_ReportPayoutsRevertsInvalidValues() public {
        uint256[] memory p = new uint256[](2);
        p[0] = 2;
        p[1] = 0;

        vm.prank(oracle);
        vm.expectRevert(Resolution.InvalidPayoutValues.selector);
        resolution.reportPayouts(CONDITION_A, p, SAMPLE_CID);
    }

    // ── setOracle ────────────────────────────────────────────────────

    function test_SetOracle() public {
        vm.prank(owner);
        resolution.setOracle(alice);
        assertEq(resolution.oracle(), alice);
    }

    function test_SetOracleEmitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit Resolution.OracleTransferred(oracle, alice);
        resolution.setOracle(alice);
    }

    function test_SetOracleAllowsNewOracleToReport() public {
        vm.prank(owner);
        resolution.setOracle(alice);

        vm.prank(alice);
        resolution.reportPayouts(CONDITION_A, _yesWins(), SAMPLE_CID);
        assertTrue(resolution.isReported(CONDITION_A));
    }

    function test_SetOracleRevokesOldOracle() public {
        vm.prank(owner);
        resolution.setOracle(alice);

        vm.prank(oracle);
        vm.expectRevert(Resolution.Unauthorized.selector);
        resolution.reportPayouts(CONDITION_A, _yesWins(), SAMPLE_CID);
    }

    function test_SetOracleRevertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        resolution.setOracle(bob);
    }

    function test_SetOracleRevertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(Resolution.ZeroAddress.selector);
        resolution.setOracle(address(0));
    }

    // ── renounceOwnership ──────────────────────────────────────────

    function test_RenounceOwnershipReverts() public {
        vm.prank(owner);
        vm.expectRevert(Resolution.RenounceDisabled.selector);
        resolution.renounceOwnership();
    }

    // ── View functions ───────────────────────────────────────────────

    function test_IsReportedFalseForUnknown() public view {
        assertFalse(resolution.isReported(CONDITION_A));
    }

    function test_GetPayoutsEmptyForUnknown() public view {
        uint256[] memory p = resolution.getPayouts(CONDITION_A);
        assertEq(p.length, 0);
    }

    // ── Fuzz ─────────────────────────────────────────────────────────

    function testFuzz_ReportPayoutsRandomConditionId(bytes32 conditionId) public {
        vm.prank(oracle);
        resolution.reportPayouts(conditionId, _yesWins(), SAMPLE_CID);

        assertTrue(resolution.isReported(conditionId));
        uint256[] memory p = resolution.getPayouts(conditionId);
        assertEq(p[0], 1);
        assertEq(p[1], 0);
        assertEq(resolution.getIpfsCid(conditionId), SAMPLE_CID);
    }

    function testFuzz_ReportPayoutsRandomConditionIdNoWins(bytes32 conditionId) public {
        vm.prank(oracle);
        resolution.reportPayouts(conditionId, _noWins(), SAMPLE_CID);

        assertTrue(resolution.isReported(conditionId));
        uint256[] memory p = resolution.getPayouts(conditionId);
        assertEq(p[0], 0);
        assertEq(p[1], 1);
    }

    function testFuzz_ReportPayoutsRandomCid(bytes32 conditionId, string calldata ipfsCid) public {
        vm.prank(oracle);
        resolution.reportPayouts(conditionId, _yesWins(), ipfsCid);

        assertTrue(resolution.isReported(conditionId));
        assertEq(resolution.getIpfsCid(conditionId), ipfsCid);
    }

    function testFuzz_ReportPayoutsRevertsInvalidValues(uint256 a, uint256 b) public {
        vm.assume(!((a == 1 && b == 0) || (a == 0 && b == 1)));

        uint256[] memory p = new uint256[](2);
        p[0] = a;
        p[1] = b;

        vm.prank(oracle);
        vm.expectRevert(Resolution.InvalidPayoutValues.selector);
        resolution.reportPayouts(CONDITION_A, p, SAMPLE_CID);
    }
}
