// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Resolution} from "../src/Resolution.sol";
import {MockConditionalTokens} from "./mocks/MockConditionalTokens.sol";

contract ResolutionTest is Test {
    Resolution public resolution;
    MockConditionalTokens public ctf;

    address public owner = address(0x1);
    address public oracle = address(0x2);
    address public alice = address(0x3);
    address public bob = address(0x4);

    bytes32 public CONDITION_A;
    bytes32 public CONDITION_B;
    bytes32 constant QUESTION_A = keccak256("question-A");
    bytes32 constant QUESTION_B = keccak256("question-B");
    string constant SAMPLE_CID = "QmTestCID1234567890abcdefghijklmnopqrstuvwxyz";

    uint256 constant DEFAULT_COOLDOWN = 12 hours;

    function setUp() public {
        ctf = new MockConditionalTokens();
        resolution = new Resolution(owner, oracle, address(ctf), DEFAULT_COOLDOWN);

        // Derive conditionIds from the CTF, using Resolution's address as the oracle.
        // This matches production: conditionId = keccak256(oracle, questionId, 2).
        CONDITION_A = ctf.getConditionId(address(resolution), QUESTION_A, 2);
        CONDITION_B = ctf.getConditionId(address(resolution), QUESTION_B, 2);

        // Prepare conditions on the CTF so finalizePayouts can forward.
        ctf.prepareCondition(address(resolution), QUESTION_A, 2);
        ctf.prepareCondition(address(resolution), QUESTION_B, 2);
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

    function _cancelled() internal pure returns (uint256[] memory) {
        uint256[] memory p = new uint256[](2);
        p[0] = 1;
        p[1] = 1;
        return p;
    }

    /// @dev Submit a report and finalize it (warp past cooldown).
    function _reportAndFinalize(bytes32 conditionId, bytes32 questionId, uint256[] memory payouts, string memory cid)
        internal
    {
        vm.prank(oracle);
        resolution.reportPayouts(conditionId, questionId, payouts, cid);
        vm.warp(block.timestamp + DEFAULT_COOLDOWN);
        resolution.finalizePayouts(conditionId);
    }

    // ── Deployment ───────────────────────────────────────────────────

    function test_Owner() public view {
        assertEq(resolution.owner(), owner);
    }

    function test_Oracle() public view {
        assertEq(resolution.oracle(), oracle);
    }

    function test_CtfAddress() public view {
        assertEq(address(resolution.ctf()), address(ctf));
    }

    function test_CooldownPeriod() public view {
        assertEq(resolution.cooldownPeriod(), DEFAULT_COOLDOWN);
    }

    function test_ConstructorEmitsOracleTransferred() public {
        vm.expectEmit(true, true, false, true);
        emit Resolution.OracleTransferred(address(0), oracle);
        new Resolution(owner, oracle, address(ctf), DEFAULT_COOLDOWN);
    }

    function test_ConstructorRevertsZeroOracle() public {
        vm.expectRevert(Resolution.ZeroAddress.selector);
        new Resolution(owner, address(0), address(ctf), DEFAULT_COOLDOWN);
    }

    function test_ConstructorRevertsZeroCtf() public {
        vm.expectRevert(Resolution.ZeroAddress.selector);
        new Resolution(owner, oracle, address(0), DEFAULT_COOLDOWN);
    }

    function test_ConstructorRevertsCooldownTooLow() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Resolution.CooldownOutOfRange.selector, 30 minutes, resolution.MIN_COOLDOWN(), resolution.MAX_COOLDOWN()
            )
        );
        new Resolution(owner, oracle, address(ctf), 30 minutes);
    }

    function test_ConstructorRevertsCooldownTooHigh() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Resolution.CooldownOutOfRange.selector, 73 hours, resolution.MIN_COOLDOWN(), resolution.MAX_COOLDOWN()
            )
        );
        new Resolution(owner, oracle, address(ctf), 73 hours);
    }

    // ── prepareCondition ──────────────────────────────────────────────

    function test_PrepareConditionCallsCtf() public {
        bytes32 newQuestion = keccak256("new-market");

        vm.prank(oracle);
        resolution.prepareCondition(newQuestion);

        // The condition should exist in the CTF with Resolution as oracle.
        bytes32 newConditionId = ctf.getConditionId(address(resolution), newQuestion, 2);
        assertEq(ctf.getOutcomeSlotCount(newConditionId), 2);
    }

    function test_PrepareConditionRevertsForNonOracle() public {
        vm.prank(alice);
        vm.expectRevert(Resolution.Unauthorized.selector);
        resolution.prepareCondition(keccak256("unauthorized"));
    }

    function test_PrepareConditionRevertsWhenPaused() public {
        vm.prank(owner);
        resolution.pause();

        vm.prank(oracle);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        resolution.prepareCondition(keccak256("paused-market"));
    }

    // ── reportPayouts (pending state) ───────────────────────────────

    function test_ReportPayoutsSetsPendingState() public {
        vm.prank(oracle);
        resolution.reportPayouts(CONDITION_A, QUESTION_A, _yesWins(), SAMPLE_CID);

        assertTrue(resolution.isPending(CONDITION_A));
        assertFalse(resolution.isReported(CONDITION_A));

        (uint256[] memory payouts, string memory cid, bytes32 qId, uint256 finalizeAfter, bool exists) =
            resolution.getPendingReport(CONDITION_A);
        assertTrue(exists);
        assertEq(payouts[0], 1);
        assertEq(payouts[1], 0);
        assertEq(cid, SAMPLE_CID);
        assertEq(qId, QUESTION_A);
        assertEq(finalizeAfter, block.timestamp + DEFAULT_COOLDOWN);
    }

    function test_ReportPayoutsDoesNotSetReported() public {
        vm.prank(oracle);
        resolution.reportPayouts(CONDITION_A, QUESTION_A, _yesWins(), SAMPLE_CID);

        assertFalse(resolution.isReported(CONDITION_A));
        assertEq(resolution.getPayouts(CONDITION_A).length, 0);
    }

    function test_ReportPayoutsEmitsPendingEvent() public {
        uint256 expectedFinalizeAfter = block.timestamp + DEFAULT_COOLDOWN;

        vm.prank(oracle);
        vm.expectEmit(true, false, false, true);
        emit Resolution.PayoutsPending(CONDITION_A, _yesWins(), SAMPLE_CID, expectedFinalizeAfter);
        resolution.reportPayouts(CONDITION_A, QUESTION_A, _yesWins(), SAMPLE_CID);
    }

    function test_ReportPayoutsEmptyCidAllowed() public {
        vm.prank(oracle);
        resolution.reportPayouts(CONDITION_A, QUESTION_A, _yesWins(), "");

        assertTrue(resolution.isPending(CONDITION_A));
    }

    function test_ReportPayoutsRevertsForNonOracle() public {
        vm.prank(alice);
        vm.expectRevert(Resolution.Unauthorized.selector);
        resolution.reportPayouts(CONDITION_A, QUESTION_A, _yesWins(), SAMPLE_CID);
    }

    function test_ReportPayoutsRevertsForOwnerNotOracle() public {
        vm.prank(owner);
        vm.expectRevert(Resolution.Unauthorized.selector);
        resolution.reportPayouts(CONDITION_A, QUESTION_A, _yesWins(), SAMPLE_CID);
    }

    function test_ReportPayoutsRevertsWhilePending() public {
        vm.startPrank(oracle);
        resolution.reportPayouts(CONDITION_A, QUESTION_A, _yesWins(), SAMPLE_CID);

        vm.expectRevert(abi.encodeWithSelector(Resolution.ReportAlreadyPending.selector, CONDITION_A));
        resolution.reportPayouts(CONDITION_A, QUESTION_A, _noWins(), SAMPLE_CID);
        vm.stopPrank();
    }

    function test_ReportPayoutsRevertsAlreadyFinalized() public {
        _reportAndFinalize(CONDITION_A, QUESTION_A, _yesWins(), SAMPLE_CID);

        vm.prank(oracle);
        vm.expectRevert(abi.encodeWithSelector(Resolution.AlreadyReported.selector, CONDITION_A));
        resolution.reportPayouts(CONDITION_A, QUESTION_A, _noWins(), SAMPLE_CID);
    }

    function test_ReportPayoutsRevertsEmptyArray() public {
        uint256[] memory empty = new uint256[](0);

        vm.prank(oracle);
        vm.expectRevert(abi.encodeWithSelector(Resolution.InvalidPayoutsLength.selector, 0));
        resolution.reportPayouts(CONDITION_A, QUESTION_A, empty, SAMPLE_CID);
    }

    function test_ReportPayoutsRevertsLengthOne() public {
        uint256[] memory one = new uint256[](1);
        one[0] = 1;

        vm.prank(oracle);
        vm.expectRevert(abi.encodeWithSelector(Resolution.InvalidPayoutsLength.selector, 1));
        resolution.reportPayouts(CONDITION_A, QUESTION_A, one, SAMPLE_CID);
    }

    function test_ReportPayoutsRevertsLengthThree() public {
        uint256[] memory three = new uint256[](3);
        three[0] = 1;

        vm.prank(oracle);
        vm.expectRevert(abi.encodeWithSelector(Resolution.InvalidPayoutsLength.selector, 3));
        resolution.reportPayouts(CONDITION_A, QUESTION_A, three, SAMPLE_CID);
    }

    function test_ReportPayoutsRevertsBothZero() public {
        uint256[] memory p = new uint256[](2);

        vm.prank(oracle);
        vm.expectRevert(Resolution.InvalidPayoutValues.selector);
        resolution.reportPayouts(CONDITION_A, QUESTION_A, p, SAMPLE_CID);
    }

    function test_ReportPayoutsRevertsInvalidValues() public {
        uint256[] memory p = new uint256[](2);
        p[0] = 2;
        p[1] = 0;

        vm.prank(oracle);
        vm.expectRevert(Resolution.InvalidPayoutValues.selector);
        resolution.reportPayouts(CONDITION_A, QUESTION_A, p, SAMPLE_CID);
    }

    /// @dev Supplying a valid conditionId with the wrong questionId should revert,
    ///      because the CTF derivation keccak256(oracle, questionId, 2) won't match.
    function test_ReportPayoutsRevertsConditionQuestionIdMismatch() public {
        bytes32 expectedConditionId = ctf.getConditionId(address(resolution), QUESTION_B, 2);

        vm.prank(oracle);
        vm.expectRevert(
            abi.encodeWithSelector(Resolution.ConditionQuestionIdMismatch.selector, CONDITION_A, expectedConditionId)
        );
        resolution.reportPayouts(CONDITION_A, QUESTION_B, _yesWins(), SAMPLE_CID);
    }

    /// @dev Supplying an arbitrary conditionId that was never derived from the given
    ///      questionId should revert, even if the questionId itself is valid.
    function test_ReportPayoutsRevertsWrongConditionId() public {
        bytes32 wrongConditionId = keccak256("totally-wrong");
        bytes32 expectedConditionId = ctf.getConditionId(address(resolution), QUESTION_A, 2);

        vm.prank(oracle);
        vm.expectRevert(
            abi.encodeWithSelector(
                Resolution.ConditionQuestionIdMismatch.selector, wrongConditionId, expectedConditionId
            )
        );
        resolution.reportPayouts(wrongConditionId, QUESTION_A, _yesWins(), SAMPLE_CID);
    }

    /// @dev A conditionId prepared on the CTF by a different oracle address should revert,
    ///      because Resolution can only resolve conditions where it is the CTF oracle.
    function test_ReportPayoutsRevertsConditionFromDifferentOracle() public {
        address attacker = address(0xBAD);
        bytes32 questionId = keccak256("attacker-question");
        ctf.prepareCondition(attacker, questionId, 2);
        bytes32 attackerConditionId = ctf.getConditionId(attacker, questionId, 2);
        bytes32 expectedConditionId = ctf.getConditionId(address(resolution), questionId, 2);

        vm.prank(oracle);
        vm.expectRevert(
            abi.encodeWithSelector(
                Resolution.ConditionQuestionIdMismatch.selector, attackerConditionId, expectedConditionId
            )
        );
        resolution.reportPayouts(attackerConditionId, questionId, _yesWins(), SAMPLE_CID);
    }

    // ── finalizePayouts ─────────────────────────────────────────────

    function test_FinalizePayoutsYesWins() public {
        _reportAndFinalize(CONDITION_A, QUESTION_A, _yesWins(), SAMPLE_CID);

        assertTrue(resolution.isReported(CONDITION_A));
        assertFalse(resolution.isPending(CONDITION_A));

        uint256[] memory p = resolution.getPayouts(CONDITION_A);
        assertEq(p[0], 1);
        assertEq(p[1], 0);
        assertEq(resolution.getIpfsCid(CONDITION_A), SAMPLE_CID);
    }

    function test_FinalizePayoutsNoWins() public {
        _reportAndFinalize(CONDITION_A, QUESTION_A, _noWins(), SAMPLE_CID);

        uint256[] memory p = resolution.getPayouts(CONDITION_A);
        assertEq(p[0], 0);
        assertEq(p[1], 1);
    }

    function test_FinalizePayoutsCancelled() public {
        _reportAndFinalize(CONDITION_A, QUESTION_A, _cancelled(), SAMPLE_CID);

        uint256[] memory p = resolution.getPayouts(CONDITION_A);
        assertEq(p[0], 1);
        assertEq(p[1], 1);
    }

    function test_FinalizePayoutsEmitsPayoutsReported() public {
        vm.prank(oracle);
        resolution.reportPayouts(CONDITION_A, QUESTION_A, _yesWins(), SAMPLE_CID);
        vm.warp(block.timestamp + DEFAULT_COOLDOWN);

        vm.expectEmit(true, false, false, true);
        emit Resolution.PayoutsReported(CONDITION_A, _yesWins(), SAMPLE_CID);
        resolution.finalizePayouts(CONDITION_A);
    }

    function test_FinalizePayoutsClearsPendingState() public {
        _reportAndFinalize(CONDITION_A, QUESTION_A, _yesWins(), SAMPLE_CID);

        assertFalse(resolution.isPending(CONDITION_A));

        (,,,, bool exists) = resolution.getPendingReport(CONDITION_A);
        assertFalse(exists);
    }

    function test_FinalizePayoutsPermissionless() public {
        vm.prank(oracle);
        resolution.reportPayouts(CONDITION_A, QUESTION_A, _yesWins(), SAMPLE_CID);
        vm.warp(block.timestamp + DEFAULT_COOLDOWN);

        // Alice (non-oracle, non-owner) can finalize.
        vm.prank(alice);
        resolution.finalizePayouts(CONDITION_A);
        assertTrue(resolution.isReported(CONDITION_A));
    }

    function test_FinalizePayoutsRevertsBeforeCooldown() public {
        vm.prank(oracle);
        resolution.reportPayouts(CONDITION_A, QUESTION_A, _yesWins(), SAMPLE_CID);

        uint256 finalizeAfter = block.timestamp + DEFAULT_COOLDOWN;

        // Warp to 1 second before cooldown ends.
        vm.warp(finalizeAfter - 1);
        vm.expectRevert(abi.encodeWithSelector(Resolution.CooldownNotElapsed.selector, CONDITION_A, finalizeAfter));
        resolution.finalizePayouts(CONDITION_A);
    }

    function test_FinalizePayoutsRevertsNoPending() public {
        vm.expectRevert(abi.encodeWithSelector(Resolution.NoPendingReport.selector, CONDITION_A));
        resolution.finalizePayouts(CONDITION_A);
    }

    function test_FinalizePayoutsMultipleConditions() public {
        vm.startPrank(oracle);
        resolution.reportPayouts(CONDITION_A, QUESTION_A, _yesWins(), SAMPLE_CID);
        resolution.reportPayouts(CONDITION_B, QUESTION_B, _noWins(), "");
        vm.stopPrank();

        vm.warp(block.timestamp + DEFAULT_COOLDOWN);

        resolution.finalizePayouts(CONDITION_A);
        resolution.finalizePayouts(CONDITION_B);

        assertTrue(resolution.isReported(CONDITION_A));
        assertTrue(resolution.isReported(CONDITION_B));

        assertEq(resolution.getPayouts(CONDITION_A)[0], 1);
        assertEq(resolution.getPayouts(CONDITION_B)[0], 0);

        assertEq(resolution.getIpfsCid(CONDITION_A), SAMPLE_CID);
        assertEq(resolution.getIpfsCid(CONDITION_B), "");
    }

    // ── CTF forwarding (H-02 fix) ───────────────────────────────────

    function test_FinalizePayoutsForwardsToCtf() public {
        _reportAndFinalize(CONDITION_A, QUESTION_A, _yesWins(), SAMPLE_CID);

        // CTF should now have payouts set. Derive the conditionId as the CTF does.
        bytes32 ctfConditionId = ctf.getConditionId(address(resolution), QUESTION_A, 2);
        assertGt(ctf.payoutDenominator(ctfConditionId), 0);
        assertEq(ctf.payoutNumerators(ctfConditionId, 0), 1);
        assertEq(ctf.payoutNumerators(ctfConditionId, 1), 0);
    }

    function test_FinalizePayoutsForwardsCancelledToCtf() public {
        _reportAndFinalize(CONDITION_A, QUESTION_A, _cancelled(), SAMPLE_CID);

        bytes32 ctfConditionId = ctf.getConditionId(address(resolution), QUESTION_A, 2);
        assertEq(ctf.payoutDenominator(ctfConditionId), 2); // 1+1
        assertEq(ctf.payoutNumerators(ctfConditionId, 0), 1);
        assertEq(ctf.payoutNumerators(ctfConditionId, 1), 1);
    }

    // ── overrideReport ──────────────────────────────────────────────

    function test_OverrideReportChangesPayouts() public {
        vm.prank(oracle);
        resolution.reportPayouts(CONDITION_A, QUESTION_A, _yesWins(), SAMPLE_CID);

        vm.prank(owner);
        resolution.overrideReport(CONDITION_A, _noWins(), "override-cid");

        (uint256[] memory payouts, string memory cid,,, bool exists) = resolution.getPendingReport(CONDITION_A);
        assertTrue(exists);
        assertEq(payouts[0], 0);
        assertEq(payouts[1], 1);
        assertEq(cid, "override-cid");
    }

    function test_OverrideReportResetsCooldown() public {
        vm.prank(oracle);
        resolution.reportPayouts(CONDITION_A, QUESTION_A, _yesWins(), SAMPLE_CID);

        // Warp halfway through cooldown, then override.
        vm.warp(block.timestamp + DEFAULT_COOLDOWN / 2);

        vm.prank(owner);
        resolution.overrideReport(CONDITION_A, _noWins(), "override-cid");

        (,,, uint256 finalizeAfter,) = resolution.getPendingReport(CONDITION_A);
        assertEq(finalizeAfter, block.timestamp + DEFAULT_COOLDOWN);
    }

    function test_OverrideReportEmitsEvent() public {
        vm.prank(oracle);
        resolution.reportPayouts(CONDITION_A, QUESTION_A, _yesWins(), SAMPLE_CID);

        uint256 expectedFinalizeAfter = block.timestamp + DEFAULT_COOLDOWN;

        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit Resolution.ReportOverridden(CONDITION_A, _noWins(), "override-cid", expectedFinalizeAfter);
        resolution.overrideReport(CONDITION_A, _noWins(), "override-cid");
    }

    function test_OverrideReportToCancelled() public {
        vm.prank(oracle);
        resolution.reportPayouts(CONDITION_A, QUESTION_A, _yesWins(), SAMPLE_CID);

        vm.prank(owner);
        resolution.overrideReport(CONDITION_A, _cancelled(), "cancel-cid");

        (uint256[] memory payouts,,,,) = resolution.getPendingReport(CONDITION_A);
        assertEq(payouts[0], 1);
        assertEq(payouts[1], 1);
    }

    function test_OverrideReportPreservesQuestionId() public {
        vm.prank(oracle);
        resolution.reportPayouts(CONDITION_A, QUESTION_A, _yesWins(), SAMPLE_CID);

        vm.prank(owner);
        resolution.overrideReport(CONDITION_A, _noWins(), "override-cid");

        (,, bytes32 qId,,) = resolution.getPendingReport(CONDITION_A);
        assertEq(qId, QUESTION_A);
    }

    function test_OverrideThenFinalize() public {
        vm.prank(oracle);
        resolution.reportPayouts(CONDITION_A, QUESTION_A, _yesWins(), SAMPLE_CID);

        vm.prank(owner);
        resolution.overrideReport(CONDITION_A, _noWins(), "override-cid");

        vm.warp(block.timestamp + DEFAULT_COOLDOWN);
        resolution.finalizePayouts(CONDITION_A);

        // Finalized with the overridden payouts.
        uint256[] memory p = resolution.getPayouts(CONDITION_A);
        assertEq(p[0], 0);
        assertEq(p[1], 1);
        assertEq(resolution.getIpfsCid(CONDITION_A), "override-cid");

        // CTF also received the overridden payouts.
        bytes32 ctfConditionId = ctf.getConditionId(address(resolution), QUESTION_A, 2);
        assertEq(ctf.payoutNumerators(ctfConditionId, 0), 0);
        assertEq(ctf.payoutNumerators(ctfConditionId, 1), 1);
    }

    function test_OverrideReportRevertsNoPending() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Resolution.NoPendingReport.selector, CONDITION_A));
        resolution.overrideReport(CONDITION_A, _noWins(), "override-cid");
    }

    function test_OverrideReportRevertsNonOwner() public {
        vm.prank(oracle);
        resolution.reportPayouts(CONDITION_A, QUESTION_A, _yesWins(), SAMPLE_CID);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        resolution.overrideReport(CONDITION_A, _noWins(), "override-cid");
    }

    function test_OverrideReportRevertsInvalidPayouts() public {
        vm.prank(oracle);
        resolution.reportPayouts(CONDITION_A, QUESTION_A, _yesWins(), SAMPLE_CID);

        uint256[] memory p = new uint256[](2);

        vm.prank(owner);
        vm.expectRevert(Resolution.InvalidPayoutValues.selector);
        resolution.overrideReport(CONDITION_A, p, "override-cid");
    }

    function test_OverrideReportRevertsInvalidLength() public {
        vm.prank(oracle);
        resolution.reportPayouts(CONDITION_A, QUESTION_A, _yesWins(), SAMPLE_CID);

        uint256[] memory p = new uint256[](3);
        p[0] = 1;

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Resolution.InvalidPayoutsLength.selector, 3));
        resolution.overrideReport(CONDITION_A, p, "override-cid");
    }

    // ── Pausable (M-07) ─────────────────────────────────────────────

    function test_ReportPayoutsRevertsWhenPaused() public {
        vm.prank(owner);
        resolution.pause();

        vm.prank(oracle);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        resolution.reportPayouts(CONDITION_A, QUESTION_A, _yesWins(), SAMPLE_CID);
    }

    function test_OverrideReportWorksWhenPaused() public {
        vm.prank(oracle);
        resolution.reportPayouts(CONDITION_A, QUESTION_A, _yesWins(), SAMPLE_CID);

        vm.startPrank(owner);
        resolution.pause();
        resolution.overrideReport(CONDITION_A, _noWins(), "override-cid");
        vm.stopPrank();

        (uint256[] memory payouts,,,,) = resolution.getPendingReport(CONDITION_A);
        assertEq(payouts[0], 0);
        assertEq(payouts[1], 1);
    }

    function test_FinalizePayoutsWorksWhenPaused() public {
        vm.prank(oracle);
        resolution.reportPayouts(CONDITION_A, QUESTION_A, _yesWins(), SAMPLE_CID);

        vm.prank(owner);
        resolution.pause();

        vm.warp(block.timestamp + DEFAULT_COOLDOWN);
        resolution.finalizePayouts(CONDITION_A);

        assertTrue(resolution.isReported(CONDITION_A));
    }

    function test_PauseRevertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        resolution.pause();
    }

    function test_UnpauseRevertsForNonOwner() public {
        vm.prank(owner);
        resolution.pause();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        resolution.unpause();
    }

    function test_UnpauseAllowsReporting() public {
        vm.startPrank(owner);
        resolution.pause();
        resolution.unpause();
        vm.stopPrank();

        vm.prank(oracle);
        resolution.reportPayouts(CONDITION_A, QUESTION_A, _yesWins(), SAMPLE_CID);
        assertTrue(resolution.isPending(CONDITION_A));
    }

    // ── setCooldownPeriod ───────────────────────────────────────────

    function test_SetCooldownPeriod() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit Resolution.CooldownPeriodUpdated(DEFAULT_COOLDOWN, 24 hours);
        resolution.setCooldownPeriod(24 hours);

        assertEq(resolution.cooldownPeriod(), 24 hours);
    }

    function test_SetCooldownPeriodRevertsNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        resolution.setCooldownPeriod(24 hours);
    }

    function test_SetCooldownPeriodRevertsTooLow() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Resolution.CooldownOutOfRange.selector, 30 minutes, resolution.MIN_COOLDOWN(), resolution.MAX_COOLDOWN()
            )
        );
        vm.prank(owner);
        resolution.setCooldownPeriod(30 minutes);
    }

    function test_SetCooldownPeriodRevertsTooHigh() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Resolution.CooldownOutOfRange.selector, 73 hours, resolution.MIN_COOLDOWN(), resolution.MAX_COOLDOWN()
            )
        );
        vm.prank(owner);
        resolution.setCooldownPeriod(73 hours);
    }

    function test_CooldownChangeDoesNotAffectPendingReport() public {
        vm.prank(oracle);
        resolution.reportPayouts(CONDITION_A, QUESTION_A, _yesWins(), SAMPLE_CID);

        uint256 originalFinalizeAfter = block.timestamp + DEFAULT_COOLDOWN;

        // Admin changes cooldown to 72 hours — but the pending report keeps its original deadline.
        vm.prank(owner);
        resolution.setCooldownPeriod(72 hours);

        (,,, uint256 finalizeAfter,) = resolution.getPendingReport(CONDITION_A);
        assertEq(finalizeAfter, originalFinalizeAfter);

        // Can still finalize at the original time.
        vm.warp(originalFinalizeAfter);
        resolution.finalizePayouts(CONDITION_A);
        assertTrue(resolution.isReported(CONDITION_A));
    }

    function test_OverrideUsesCurrentCooldownPeriod() public {
        vm.prank(oracle);
        resolution.reportPayouts(CONDITION_A, QUESTION_A, _yesWins(), SAMPLE_CID);

        // Admin changes cooldown to 24 hours, then overrides.
        vm.startPrank(owner);
        resolution.setCooldownPeriod(24 hours);
        resolution.overrideReport(CONDITION_A, _noWins(), "override-cid");
        vm.stopPrank();

        (,,, uint256 finalizeAfter,) = resolution.getPendingReport(CONDITION_A);
        assertEq(finalizeAfter, block.timestamp + 24 hours);
    }

    // ── setOracle ───────────────────────────────────────────────────

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
        resolution.reportPayouts(CONDITION_A, QUESTION_A, _yesWins(), SAMPLE_CID);
        assertTrue(resolution.isPending(CONDITION_A));
    }

    function test_SetOracleRevokesOldOracle() public {
        vm.prank(owner);
        resolution.setOracle(alice);

        vm.prank(oracle);
        vm.expectRevert(Resolution.Unauthorized.selector);
        resolution.reportPayouts(CONDITION_A, QUESTION_A, _yesWins(), SAMPLE_CID);
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

    // ── transferOwnership (two-step) ────────────────────────────────

    function test_TransferOwnershipSetsPendingOwner() public {
        vm.prank(owner);
        resolution.transferOwnership(alice);

        assertEq(resolution.pendingOwner(), alice);
        assertEq(resolution.owner(), owner);
    }

    function test_AcceptOwnershipCompletes() public {
        vm.prank(owner);
        resolution.transferOwnership(alice);

        vm.prank(alice);
        resolution.acceptOwnership();

        assertEq(resolution.owner(), alice);
        assertEq(resolution.pendingOwner(), address(0));
    }

    function test_AcceptOwnershipRevertsForNonPending() public {
        vm.prank(owner);
        resolution.transferOwnership(alice);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        resolution.acceptOwnership();
    }

    function test_TransferOwnershipRevertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        resolution.transferOwnership(bob);
    }

    // ── renounceOwnership ──────────────────────────────────────────

    function test_RenounceOwnershipReverts() public {
        vm.prank(owner);
        vm.expectRevert(Resolution.RenounceDisabled.selector);
        resolution.renounceOwnership();
    }

    // ── View functions ──────────────────────────────────────────────

    function test_IsReportedFalseForUnknown() public view {
        assertFalse(resolution.isReported(CONDITION_A));
    }

    function test_GetPayoutsEmptyForUnknown() public view {
        uint256[] memory p = resolution.getPayouts(CONDITION_A);
        assertEq(p.length, 0);
    }

    function test_GetIpfsCidEmptyForUnknown() public view {
        assertEq(resolution.getIpfsCid(CONDITION_A), "");
    }

    function test_IsPendingFalseForUnknown() public view {
        assertFalse(resolution.isPending(CONDITION_A));
    }

    function test_GetPendingReportForUnknown() public view {
        (,,,, bool exists) = resolution.getPendingReport(CONDITION_A);
        assertFalse(exists);
    }

    // ── Fuzz ────────────────────────────────────────────────────────

    function testFuzz_ReportAndFinalizeRandomQuestionId(bytes32 questionId) public {
        // Skip questionIds already prepared in setUp to avoid ConditionAlreadyPrepared.
        vm.assume(questionId != QUESTION_A && questionId != QUESTION_B);

        // Derive conditionId from the questionId using Resolution as oracle.
        ctf.prepareCondition(address(resolution), questionId, 2);
        bytes32 conditionId = ctf.getConditionId(address(resolution), questionId, 2);

        _reportAndFinalize(conditionId, questionId, _yesWins(), SAMPLE_CID);

        assertTrue(resolution.isReported(conditionId));
        uint256[] memory p = resolution.getPayouts(conditionId);
        assertEq(p[0], 1);
        assertEq(p[1], 0);
        assertEq(resolution.getIpfsCid(conditionId), SAMPLE_CID);
    }

    function testFuzz_ReportAndFinalizeRandomCid(string calldata ipfsCid) public {
        _reportAndFinalize(CONDITION_A, QUESTION_A, _yesWins(), ipfsCid);

        assertTrue(resolution.isReported(CONDITION_A));
        assertEq(resolution.getIpfsCid(CONDITION_A), ipfsCid);
    }

    function testFuzz_ReportPayoutsRevertsInvalidValues(uint256 a, uint256 b) public {
        vm.assume(!((a == 1 && b == 0) || (a == 0 && b == 1) || (a == 1 && b == 1)));

        uint256[] memory p = new uint256[](2);
        p[0] = a;
        p[1] = b;

        vm.prank(oracle);
        vm.expectRevert(Resolution.InvalidPayoutValues.selector);
        resolution.reportPayouts(CONDITION_A, QUESTION_A, p, SAMPLE_CID);
    }

    function testFuzz_CooldownPeriodRange(uint256 period) public {
        if (period >= 1 hours && period <= 72 hours) {
            vm.prank(owner);
            resolution.setCooldownPeriod(period);
            assertEq(resolution.cooldownPeriod(), period);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    Resolution.CooldownOutOfRange.selector, period, resolution.MIN_COOLDOWN(), resolution.MAX_COOLDOWN()
                )
            );
            vm.prank(owner);
            resolution.setCooldownPeriod(period);
        }
    }
}
