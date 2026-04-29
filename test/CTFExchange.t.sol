// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Order, Side, SignatureType} from "exchange/libraries/OrderStructs.sol";
import {IAuthEE} from "exchange/interfaces/IAuth.sol";
import {ITradingEE} from "exchange/interfaces/ITrading.sol";
import {IPausableEE} from "exchange/interfaces/IPausable.sol";
import {IRegistryEE} from "exchange/interfaces/IRegistry.sol";

import {ProphetCTFExchange} from "../src/ProphetCTFExchange.sol";
import {Resolution} from "../src/Resolution.sol";
import {TestUSDC} from "../src/TestUSDC.sol";
import {MockConditionalTokens} from "./mocks/MockConditionalTokens.sol";

contract CTFExchangeTest is Test {
    ProphetCTFExchange public exchange;
    Resolution public resolution;
    TestUSDC public usdc;
    MockConditionalTokens public ctf;

    // Test actors
    address public admin;
    uint256 public adminKey;
    address public operator;
    uint256 public operatorKey;
    address public oracleEoa;
    uint256 public oracleKey;
    address public alice;
    uint256 public aliceKey;
    address public bob;
    uint256 public bobKey;

    // Market parameters
    bytes32 public questionId = keccak256("Will ETH reach $10k in 2026?");
    bytes32 public conditionId;
    uint256 public yesTokenId;
    uint256 public noTokenId;

    uint256 constant USDC_DECIMALS = 6;
    uint256 constant ONE_USDC = 10 ** USDC_DECIMALS;

    function setUp() public {
        // Generate deterministic keys for test actors
        (admin, adminKey) = makeAddrAndKey("admin");
        (operator, operatorKey) = makeAddrAndKey("operator");
        (oracleEoa, oracleKey) = makeAddrAndKey("oracle");
        (alice, aliceKey) = makeAddrAndKey("alice");
        (bob, bobKey) = makeAddrAndKey("bob");

        // Deploy contracts
        vm.startPrank(admin);
        usdc = new TestUSDC(admin);
        ctf = new MockConditionalTokens();

        // Deploy Resolution contract (admin=owner, oracleEoa=oracle)
        resolution = new Resolution(admin, oracleEoa, address(ctf), 12 hours);

        // Deploy exchange: admin becomes admin + operator automatically
        exchange = new ProphetCTFExchange(
            address(usdc),
            address(ctf),
            address(0), // proxyFactory (not needed for EOA tests)
            address(0) // safeFactory (not needed for EOA tests)
        );

        // Add operator role
        exchange.addOperator(operator);

        // Set the exchange oracle — authorized to call registerToken
        exchange.setOracle(oracleEoa);

        // Set the Resolution contract for condition oracle validation (H-05)
        exchange.setResolution(address(resolution));
        vm.stopPrank();

        // Prepare condition via Resolution wrapper (enforces Resolution as CTF oracle)
        vm.prank(oracleEoa);
        resolution.prepareCondition(questionId);
        conditionId = ctf.getConditionId(address(resolution), questionId, 2);

        // Compute position token IDs (matching Gnosis CTF spec)
        bytes32 yesCollectionId = ctf.getCollectionId(bytes32(0), conditionId, 1); // indexSet 1 = YES
        bytes32 noCollectionId = ctf.getCollectionId(bytes32(0), conditionId, 2); // indexSet 2 = NO
        yesTokenId = ctf.getPositionId(IERC20(address(usdc)), yesCollectionId);
        noTokenId = ctf.getPositionId(IERC20(address(usdc)), noCollectionId);

        // Register token pair on exchange
        vm.prank(admin);
        exchange.registerToken(yesTokenId, noTokenId, conditionId, questionId);

        // Fund test actors with USDC
        vm.startPrank(admin);
        usdc.mint(alice, 10_000 * ONE_USDC);
        usdc.mint(bob, 10_000 * ONE_USDC);
        usdc.mint(operator, 10_000 * ONE_USDC);
        vm.stopPrank();

        // Approve exchange to spend USDC for all actors
        _approveExchange(alice);
        _approveExchange(bob);
        _approveExchange(operator);
    }

    // ── Deployment ────────────────────────────────────────────────

    function test_Deployment_CollateralAddress() public view {
        assertEq(exchange.getCollateral(), address(usdc));
    }

    function test_Deployment_CtfAddress() public view {
        assertEq(exchange.getCtf(), address(ctf));
    }

    function test_Deployment_AdminIsSet() public view {
        assertTrue(exchange.isAdmin(admin));
    }

    function test_Deployment_OperatorIsSet() public view {
        assertTrue(exchange.isOperator(operator));
    }

    function test_Deployment_DeployerIsAdminAndOperator() public view {
        // The deployer (admin) gets both roles in constructor
        assertTrue(exchange.isAdmin(admin));
        assertTrue(exchange.isOperator(admin));
    }

    function test_Deployment_DomainSeparatorIsSet() public view {
        assertTrue(exchange.domainSeparator() != bytes32(0));
    }

    // ── Token Registration ────────────────────────────────────────

    function test_TokenRegistration_ConditionId() public view {
        assertEq(exchange.getConditionId(yesTokenId), conditionId);
        assertEq(exchange.getConditionId(noTokenId), conditionId);
    }

    function test_TokenRegistration_Complements() public view {
        assertEq(exchange.getComplement(yesTokenId), noTokenId);
        assertEq(exchange.getComplement(noTokenId), yesTokenId);
    }

    // ── fillOrder: BUY side (complementary) ───────────────────────

    function test_FillOrder_BuySide() public {
        // Alice wants to BUY YES tokens at 0.60 USDC each
        // She offers 60 USDC for 100 YES tokens (price = 0.60)
        uint256 makerAmount = 60 * ONE_USDC; // USDC to pay
        uint256 takerAmount = 100 * ONE_USDC; // YES tokens to receive

        // Operator must hold the YES tokens to fill Alice's buy order
        _mintPositionTokens(operator, 100 * ONE_USDC);

        // Approve CTF tokens for exchange
        vm.prank(operator);
        ctf.setApprovalForAll(address(exchange), true);

        Order memory order = _createOrder(alice, aliceKey, yesTokenId, makerAmount, takerAmount, Side.BUY);

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 operatorYesBefore = ctf.balanceOf(operator, yesTokenId);

        // Operator fills the order
        vm.prank(operator);
        exchange.fillOrder(order, makerAmount);

        // Alice paid USDC
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore - makerAmount);
        // Alice received YES tokens (minus fees — 0 fee in this test)
        assertEq(ctf.balanceOf(alice, yesTokenId), takerAmount);
        // Operator sent YES tokens
        assertEq(ctf.balanceOf(operator, yesTokenId), operatorYesBefore - takerAmount);
    }

    // ── fillOrder: SELL side ──────────────────────────────────────

    function test_FillOrder_SellSide() public {
        // Alice wants to SELL 100 YES tokens at 0.60 USDC each
        // She offers 100 YES tokens for 60 USDC (price = 0.60)
        uint256 makerAmount = 100 * ONE_USDC; // YES tokens to sell
        uint256 takerAmount = 60 * ONE_USDC; // USDC to receive

        // Alice needs YES tokens first
        _mintPositionTokens(alice, 100 * ONE_USDC);
        vm.prank(alice);
        ctf.setApprovalForAll(address(exchange), true);

        Order memory order = _createOrder(alice, aliceKey, yesTokenId, makerAmount, takerAmount, Side.SELL);

        uint256 aliceYesBefore = ctf.balanceOf(alice, yesTokenId);
        // Operator fills the order (provides USDC)
        vm.prank(operator);
        exchange.fillOrder(order, makerAmount);

        // Alice sent YES tokens
        assertEq(ctf.balanceOf(alice, yesTokenId), aliceYesBefore - makerAmount);
        // Alice received USDC
        assertEq(usdc.balanceOf(alice), 10_000 * ONE_USDC + takerAmount);
    }

    // ── matchOrders: COMPLEMENTARY (BUY vs SELL) ──────────────────

    function test_MatchOrders_Complementary() public {
        // Alice: BUY 100 YES at 0.60
        // Bob: SELL 100 YES at 0.60
        uint256 aliceMaker = 60 * ONE_USDC;
        uint256 aliceTaker = 100 * ONE_USDC;
        uint256 bobMaker = 100 * ONE_USDC;
        uint256 bobTaker = 60 * ONE_USDC;

        // Bob needs YES tokens to sell
        _mintPositionTokens(bob, 100 * ONE_USDC);
        vm.prank(bob);
        ctf.setApprovalForAll(address(exchange), true);

        Order memory takerOrder = _createOrder(alice, aliceKey, yesTokenId, aliceMaker, aliceTaker, Side.BUY);
        Order memory makerOrder = _createOrder(bob, bobKey, yesTokenId, bobMaker, bobTaker, Side.SELL);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;
        uint256[] memory makerFillAmounts = new uint256[](1);
        makerFillAmounts[0] = bobMaker;

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 bobYesBefore = ctf.balanceOf(bob, yesTokenId);

        vm.prank(operator);
        exchange.matchOrders(takerOrder, makerOrders, aliceMaker, makerFillAmounts);

        // Alice paid exactly 60 USDC, received exactly 100 YES tokens (0% fee)
        assertEq(usdc.balanceOf(alice), aliceUsdcBefore - aliceMaker);
        assertEq(ctf.balanceOf(alice, yesTokenId), aliceTaker);

        // Bob sent exactly 100 YES tokens, received exactly 60 USDC (0% fee)
        assertEq(ctf.balanceOf(bob, yesTokenId), bobYesBefore - bobMaker);
        assertEq(usdc.balanceOf(bob), 10_000 * ONE_USDC + bobTaker);
    }

    // ── matchOrders: MINT (both BUY — creates shares from USDC) ───

    function test_MatchOrders_Mint() public {
        // Alice: BUY YES at 0.60 (offers 60 USDC for 100 YES)
        // Bob: BUY NO at 0.40 (offers 40 USDC for 100 NO)
        // Both BUY → MINT: exchange splits 100 USDC → 100 YES + 100 NO
        // Prices sum to 1.0: crossing condition met
        uint256 aliceMaker = 60 * ONE_USDC;
        uint256 aliceTaker = 100 * ONE_USDC;
        uint256 bobMaker = 40 * ONE_USDC;
        uint256 bobTaker = 100 * ONE_USDC;

        Order memory takerOrder = _createOrder(alice, aliceKey, yesTokenId, aliceMaker, aliceTaker, Side.BUY);
        Order memory makerOrder = _createOrder(bob, bobKey, noTokenId, bobMaker, bobTaker, Side.BUY);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;
        uint256[] memory makerFillAmounts = new uint256[](1);
        makerFillAmounts[0] = bobMaker;

        // Fund exchange with enough USDC for the mint operation:
        // The exchange needs collateral to call splitPosition. During matchOrders,
        // it collects USDC from the taker (Alice), fills maker (Bob) which collects from Bob,
        // then calls splitPosition with the collected USDC.
        // Alice contributes 60, Bob contributes 40 → total 100 USDC goes to CTF for splitting

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 bobUsdcBefore = usdc.balanceOf(bob);

        vm.prank(operator);
        exchange.matchOrders(takerOrder, makerOrders, aliceMaker, makerFillAmounts);

        // Alice received YES tokens
        assertGt(ctf.balanceOf(alice, yesTokenId), 0);
        // Bob received NO tokens
        assertGt(ctf.balanceOf(bob, noTokenId), 0);
        // Both paid USDC
        assertLt(usdc.balanceOf(alice), aliceUsdcBefore);
        assertLt(usdc.balanceOf(bob), bobUsdcBefore);
    }

    // ── matchOrders: MERGE (both SELL — burns shares to USDC) ─────

    function test_MatchOrders_Merge() public {
        // Alice: SELL YES at 0.60 (offers 100 YES for 60 USDC)
        // Bob: SELL NO at 0.40 (offers 100 NO for 40 USDC)
        // Both SELL → MERGE: exchange merges 100 YES + 100 NO → 100 USDC
        // Prices sum to 1.0: crossing condition met
        uint256 aliceMaker = 100 * ONE_USDC;
        uint256 aliceTaker = 60 * ONE_USDC;
        uint256 bobMaker = 100 * ONE_USDC;
        uint256 bobTaker = 40 * ONE_USDC;

        // Both need position tokens
        _mintPositionTokens(alice, 100 * ONE_USDC);
        _mintPositionTokens(bob, 100 * ONE_USDC);
        vm.prank(alice);
        ctf.setApprovalForAll(address(exchange), true);
        vm.prank(bob);
        ctf.setApprovalForAll(address(exchange), true);

        Order memory takerOrder = _createOrder(alice, aliceKey, yesTokenId, aliceMaker, aliceTaker, Side.SELL);
        Order memory makerOrder = _createOrder(bob, bobKey, noTokenId, bobMaker, bobTaker, Side.SELL);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;
        uint256[] memory makerFillAmounts = new uint256[](1);
        makerFillAmounts[0] = bobMaker;

        uint256 aliceUsdcBefore = usdc.balanceOf(alice);
        uint256 bobUsdcBefore = usdc.balanceOf(bob);

        vm.prank(operator);
        exchange.matchOrders(takerOrder, makerOrders, aliceMaker, makerFillAmounts);

        // Both received USDC from merged positions
        assertGt(usdc.balanceOf(alice), aliceUsdcBefore);
        assertGt(usdc.balanceOf(bob), bobUsdcBefore);
    }

    // ── Access control ────────────────────────────────────────────

    function test_FillOrder_RevertsForNonOperator() public {
        uint256 makerAmount = 60 * ONE_USDC;
        uint256 takerAmount = 100 * ONE_USDC;

        Order memory order = _createOrder(alice, aliceKey, yesTokenId, makerAmount, takerAmount, Side.BUY);

        // Random address (not operator) tries to fill
        vm.prank(address(0xBEEF));
        vm.expectRevert(IAuthEE.NotOperator.selector);
        exchange.fillOrder(order, makerAmount);
    }

    function test_MatchOrders_RevertsForNonOperator() public {
        Order memory takerOrder = _createOrder(alice, aliceKey, yesTokenId, 60 * ONE_USDC, 100 * ONE_USDC, Side.BUY);
        Order memory makerOrder = _createOrder(bob, bobKey, noTokenId, 40 * ONE_USDC, 100 * ONE_USDC, Side.BUY);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = makerOrder;
        uint256[] memory makerFillAmounts = new uint256[](1);
        makerFillAmounts[0] = 40 * ONE_USDC;

        vm.prank(address(0xBEEF));
        vm.expectRevert(IAuthEE.NotOperator.selector);
        exchange.matchOrders(takerOrder, makerOrders, 60 * ONE_USDC, makerFillAmounts);
    }

    // ── registerToken access control ──────────────────────────────

    function test_RegisterToken_OperatorRejected() public {
        // Operator no longer has registerToken authority — only admin and oracle.
        bytes32 question2 = keccak256("Will BTC reach $200k in 2026?");
        (bytes32 conditionId2, uint256 yesTokenId2, uint256 noTokenId2) = _prepareCondition(question2);

        vm.prank(operator);
        vm.expectRevert(ProphetCTFExchange.NotAdminOrOracle.selector);
        exchange.registerToken(yesTokenId2, noTokenId2, conditionId2, question2);
    }

    function test_RegisterToken_OracleCanCall() public {
        bytes32 question2 = keccak256("Will BTC reach $200k in 2026?");
        (bytes32 conditionId2, uint256 yesTokenId2, uint256 noTokenId2) = _prepareCondition(question2);

        vm.prank(oracleEoa);
        exchange.registerToken(yesTokenId2, noTokenId2, conditionId2, question2);

        assertEq(exchange.getConditionId(yesTokenId2), conditionId2);
        assertEq(exchange.getComplement(yesTokenId2), noTokenId2);
        assertEq(exchange.getComplement(noTokenId2), yesTokenId2);
    }

    function test_RegisterToken_AdminCanCall() public {
        // Admin retains registerToken authority as a safety net.
        bytes32 question2 = keccak256("Will SOL reach $1k in 2026?");
        (bytes32 conditionId2, uint256 yesTokenId2, uint256 noTokenId2) = _prepareCondition(question2);

        vm.prank(admin);
        exchange.registerToken(yesTokenId2, noTokenId2, conditionId2, question2);

        assertEq(exchange.getConditionId(yesTokenId2), conditionId2);
        assertEq(exchange.getComplement(yesTokenId2), noTokenId2);
    }

    function test_RegisterToken_RevertsForNonAdminNonOracle() public {
        bytes32 question2 = keccak256("Will LINK reach $100 in 2026?");
        (bytes32 conditionId2, uint256 yesTokenId2, uint256 noTokenId2) = _prepareCondition(question2);

        vm.prank(address(0xBEEF));
        vm.expectRevert(ProphetCTFExchange.NotAdminOrOracle.selector);
        exchange.registerToken(yesTokenId2, noTokenId2, conditionId2, question2);
    }

    function test_RegisterToken_RevertsOnTokenConditionMismatch() public {
        bytes32 question2 = keccak256("Will DOGE reach $1 in 2026?");
        (bytes32 conditionId2,,) = _prepareCondition(question2);

        // Use unrelated token IDs that do not match the reconstructed CTF position IDs.
        vm.prank(oracleEoa);
        vm.expectRevert(ProphetCTFExchange.TokenConditionMismatch.selector);
        exchange.registerToken(uint256(12345), uint256(67890), conditionId2, question2);
    }

    function test_RegisterToken_RevertsWhenConditionNotPrepared() public {
        // Compute token IDs for a condition that was never prepared in the CTF.
        // getConditionId / getCollectionId / getPositionId are pure math and return
        // values regardless of preparation — the new existence check must catch this.
        bytes32 fakeQuestion = keccak256("phantom condition");
        bytes32 fakeConditionId = ctf.getConditionId(address(resolution), fakeQuestion, 2);
        bytes32 yesCollection = ctf.getCollectionId(bytes32(0), fakeConditionId, 1);
        bytes32 noCollection = ctf.getCollectionId(bytes32(0), fakeConditionId, 2);
        uint256 fakeYes = ctf.getPositionId(IERC20(address(usdc)), yesCollection);
        uint256 fakeNo = ctf.getPositionId(IERC20(address(usdc)), noCollection);

        vm.prank(oracleEoa);
        vm.expectRevert(ProphetCTFExchange.ConditionNotPrepared.selector);
        exchange.registerToken(fakeYes, fakeNo, fakeConditionId, fakeQuestion);
    }

    // ── setOracle ─────────────────────────────────────────────────

    function test_SetOracle_AdminCanUpdate() public {
        address newOracle = address(0xAB1C);

        vm.expectEmit(true, true, false, false, address(exchange));
        emit OracleUpdated(oracleEoa, newOracle);

        vm.prank(admin);
        exchange.setOracle(newOracle);

        assertEq(exchange.oracle(), newOracle);
    }

    function test_SetOracle_RevertsForNonAdmin() public {
        vm.prank(operator);
        vm.expectRevert(IAuthEE.NotAdmin.selector);
        exchange.setOracle(address(0xAB1C));
    }

    function test_SetOracle_RevertsOnZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(IAuthEE.ZeroAddress.selector);
        exchange.setOracle(address(0));
    }

    // ── unregisterToken ───────────────────────────────────────────

    function test_UnregisterToken_AdminCanClear() public {
        // yesTokenId / noTokenId were registered during setUp().
        vm.expectEmit(true, true, true, false, address(exchange));
        emit TokenUnregistered(yesTokenId, noTokenId, conditionId);

        vm.prank(admin);
        exchange.unregisterToken(yesTokenId, noTokenId);

        // Both directions should now look unregistered.
        assertEq(exchange.getConditionId(yesTokenId), bytes32(0));
        assertEq(exchange.getConditionId(noTokenId), bytes32(0));
    }

    function test_UnregisterToken_RevertsForNonAdmin() public {
        vm.prank(oracleEoa);
        vm.expectRevert(IAuthEE.NotAdmin.selector);
        exchange.unregisterToken(yesTokenId, noTokenId);
    }

    function test_UnregisterToken_RevertsWhenComplementMismatch() public {
        // Passing a complement that doesn't match the stored pair should revert.
        // This prevents accidentally deleting an unrelated market's registry entry.
        uint256 bogusComplement = 999999;
        vm.prank(admin);
        vm.expectRevert(IRegistryEE.InvalidComplement.selector);
        exchange.unregisterToken(yesTokenId, bogusComplement);

        // Verify the original pair is still registered (nothing was deleted).
        assertEq(exchange.getConditionId(yesTokenId), conditionId);
        assertEq(exchange.getConditionId(noTokenId), conditionId);
    }

    function test_UnregisterToken_RevertsWhenTokenNotRegistered() public {
        // Trying to unregister a token that was never registered should revert.
        uint256 unregisteredToken = 123456;
        vm.prank(admin);
        vm.expectRevert(IRegistryEE.InvalidTokenId.selector);
        exchange.unregisterToken(unregisteredToken, 654321);
    }

    function test_UnregisterToken_WorksFromEitherDirection() public {
        // Should work when passing the pair as (noTokenId, yesTokenId) too,
        // since each token stores its complement.
        vm.prank(admin);
        exchange.unregisterToken(noTokenId, yesTokenId);

        assertEq(exchange.getConditionId(yesTokenId), bytes32(0));
        assertEq(exchange.getConditionId(noTokenId), bytes32(0));
    }

    /// @notice Once a condition is unregistered, it must never be re-registered.
    ///         Re-registration would reactivate stale signed orders at outdated prices,
    ///         allowing someone to fill forgotten orders against unsuspecting signers.
    function test_RegisterToken_RevertsDuplicatedConditionId() public {
        // Unregister the condition set up in setUp
        vm.prank(admin);
        exchange.unregisterToken(yesTokenId, noTokenId);

        // The condition is now tombstoned — attempting to re-register must revert
        vm.prank(admin);
        vm.expectRevert(ProphetCTFExchange.DuplicatedConditionId.selector);
        exchange.registerToken(yesTokenId, noTokenId, conditionId, questionId);
    }

    /// @notice Verify that previousConditionIds is set after unregistration.
    function test_UnregisterToken_SetsConditionAsPrevious() public {
        assertFalse(exchange.previousConditionIds(conditionId));

        vm.prank(admin);
        exchange.unregisterToken(yesTokenId, noTokenId);

        assertTrue(exchange.previousConditionIds(conditionId));
    }

    // ── L-04: NatSpec accuracy — unprepared conditions revert ────

    function test_ValidateTokenCondition_RejectsUnpreparedCondition() public {
        bytes32 unpreparedQuestion = keccak256("never prepared");
        bytes32 unpreparedConditionId = ctf.getConditionId(address(resolution), unpreparedQuestion, 2);

        bytes32 yesCol = ctf.getCollectionId(bytes32(0), unpreparedConditionId, 1);
        bytes32 noCol = ctf.getCollectionId(bytes32(0), unpreparedConditionId, 2);
        uint256 yesId = ctf.getPositionId(IERC20(address(usdc)), yesCol);
        uint256 noId = ctf.getPositionId(IERC20(address(usdc)), noCol);

        // Token IDs are mathematically valid, but the condition was never prepared.
        // The getOutcomeSlotCount check must catch this.
        vm.prank(admin);
        vm.expectRevert(ProphetCTFExchange.ConditionNotPrepared.selector);
        exchange.registerToken(yesId, noId, unpreparedConditionId, unpreparedQuestion);
    }

    // ── M-10: constructor zero-address checks ────────────────────

    function test_Constructor_RevertsOnZeroCollateral() public {
        vm.expectRevert(IAuthEE.ZeroAddress.selector);
        new ProphetCTFExchange(address(0), address(ctf), address(0), address(0));
    }

    function test_Constructor_RevertsOnZeroCtf() public {
        vm.expectRevert(IAuthEE.ZeroAddress.selector);
        new ProphetCTFExchange(address(usdc), address(0), address(0), address(0));
    }

    function test_Constructor_RevertsOnBothZero() public {
        vm.expectRevert(IAuthEE.ZeroAddress.selector);
        new ProphetCTFExchange(address(0), address(0), address(0), address(0));
    }

    // ── M-06: registerToken blocked when paused ───────────────────

    function test_RegisterToken_RevertsWhenPaused() public {
        bytes32 question2 = keccak256("Will ETH reach $20k in 2026?");
        (bytes32 conditionId2, uint256 yesTokenId2, uint256 noTokenId2) = _prepareCondition(question2);

        vm.prank(admin);
        exchange.pauseTrading();

        vm.prank(oracleEoa);
        vm.expectRevert(IPausableEE.Paused.selector);
        exchange.registerToken(yesTokenId2, noTokenId2, conditionId2, question2);

        vm.prank(admin);
        vm.expectRevert(IPausableEE.Paused.selector);
        exchange.registerToken(yesTokenId2, noTokenId2, conditionId2, question2);
    }

    function test_RegisterToken_WorksAfterUnpause() public {
        bytes32 question2 = keccak256("Will ETH reach $20k in 2026?");
        (bytes32 conditionId2, uint256 yesTokenId2, uint256 noTokenId2) = _prepareCondition(question2);

        vm.startPrank(admin);
        exchange.pauseTrading();
        exchange.unpauseTrading();
        vm.stopPrank();

        vm.prank(oracleEoa);
        exchange.registerToken(yesTokenId2, noTokenId2, conditionId2, question2);
        assertEq(exchange.getConditionId(yesTokenId2), conditionId2);
    }

    // Events mirrored from ProphetCTFExchange for expectEmit matching.
    event OracleUpdated(address indexed previousOracle, address indexed newOracle);
    event TokenUnregistered(uint256 indexed token0, uint256 indexed token1, bytes32 indexed conditionId);

    function test_AddOperator_RevertsForOperator() public {
        vm.prank(operator);
        vm.expectRevert(IAuthEE.NotAdmin.selector);
        exchange.addOperator(address(0xCAFE));
    }

    function test_RemoveOperator_RevertsForOperator() public {
        vm.prank(operator);
        vm.expectRevert(IAuthEE.NotAdmin.selector);
        exchange.removeOperator(operator);
    }

    function test_PauseTrading_RevertsForOperator() public {
        vm.prank(operator);
        vm.expectRevert(IAuthEE.NotAdmin.selector);
        exchange.pauseTrading();
    }

    // ── Order expiration ──────────────────────────────────────────

    function test_FillOrder_RevertsOnExpiredOrder() public {
        // Warp to a realistic timestamp so block.timestamp - 1 != 0
        vm.warp(1_700_000_000);

        uint256 makerAmount = 60 * ONE_USDC;
        uint256 takerAmount = 100 * ONE_USDC;

        // Create order that expires in the past
        Order memory order = Order({
            salt: 1,
            maker: alice,
            signer: alice,
            taker: address(0),
            tokenId: yesTokenId,
            makerAmount: makerAmount,
            takerAmount: takerAmount,
            expiration: block.timestamp - 1, // already expired
            nonce: 0,
            feeRateBps: 0,
            side: Side.BUY,
            signatureType: SignatureType.EOA,
            signature: ""
        });

        // Sign the order
        bytes32 orderHash = exchange.hashOrder(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(aliceKey, orderHash);
        order.signature = abi.encodePacked(r, s, v);

        _mintPositionTokens(operator, 100 * ONE_USDC);
        vm.prank(operator);
        ctf.setApprovalForAll(address(exchange), true);

        vm.prank(operator);
        vm.expectRevert(ITradingEE.OrderExpired.selector);
        exchange.fillOrder(order, makerAmount);
    }

    // ── Pause ─────────────────────────────────────────────────────

    function test_FillOrder_RevertsWhenPaused() public {
        vm.prank(admin);
        exchange.pauseTrading();

        Order memory order = _createOrder(alice, aliceKey, yesTokenId, 60 * ONE_USDC, 100 * ONE_USDC, Side.BUY);

        vm.prank(operator);
        vm.expectRevert(IPausableEE.Paused.selector);
        exchange.fillOrder(order, 60 * ONE_USDC);
    }

    // ── POLY_GNOSIS_SAFE signature type ───────────────────────────

    function test_SignatureType_PolyGnosisSafeExists() public pure {
        // Verify POLY_GNOSIS_SAFE enum value exists and equals 2
        assertEq(uint8(SignatureType.POLY_GNOSIS_SAFE), 2);
    }

    function test_SignatureType_AllTypesExist() public pure {
        assertEq(uint8(SignatureType.EOA), 0);
        assertEq(uint8(SignatureType.POLY_PROXY), 1);
        assertEq(uint8(SignatureType.POLY_GNOSIS_SAFE), 2);
        assertEq(uint8(SignatureType.POLY_1271), 3);
    }

    // ── Partial fill ──────────────────────────────────────────────

    function test_FillOrder_PartialFill() public {
        // Alice: BUY 100 YES at 0.60
        uint256 makerAmount = 60 * ONE_USDC;
        uint256 takerAmount = 100 * ONE_USDC;

        _mintPositionTokens(operator, 100 * ONE_USDC);
        vm.prank(operator);
        ctf.setApprovalForAll(address(exchange), true);

        Order memory order = _createOrder(alice, aliceKey, yesTokenId, makerAmount, takerAmount, Side.BUY);

        // Fill only half
        uint256 halfMaker = makerAmount / 2;

        vm.prank(operator);
        exchange.fillOrder(order, halfMaker);

        // Alice received half the YES tokens
        assertEq(ctf.balanceOf(alice, yesTokenId), takerAmount / 2);
        // Order is not fully filled — can fill the rest
        assertFalse(exchange.getOrderStatus(exchange.hashOrder(order)).isFilledOrCancelled);
    }

    // ── Cancel order ──────────────────────────────────────────────

    function test_CancelOrder() public {
        Order memory order = _createOrder(alice, aliceKey, yesTokenId, 60 * ONE_USDC, 100 * ONE_USDC, Side.BUY);

        vm.prank(alice);
        exchange.cancelOrder(order);

        assertTrue(exchange.getOrderStatus(exchange.hashOrder(order)).isFilledOrCancelled);
    }

    // ── sweepFees ─────────────────────────────────────────────────

    /// @notice Operator with unequal YES/NO balances can sweep the minimum of the
    ///         two back into collateral. The leftover (unpaired) tokens remain.
    function test_SweepFees_MergesMinimumBalance() public {
        // Give operator 50 YES + 30 NO (simulating fee accumulation)
        _mintPositionTokens(operator, 50 * ONE_USDC);
        // Mint another batch and only give YES to operator to create imbalance
        _mintPositionTokens(address(this), 30 * ONE_USDC);
        // Operator now has 50 YES from first mint. Give 30 NO from second.
        ctf.safeTransferFrom(address(this), operator, noTokenId, 30 * ONE_USDC, "");

        // Operator: 50 YES, 80 NO (50 from first mint + 30 transferred)
        // Wait — let me recalculate. _mintPositionTokens gives `to` both YES+NO.
        // So operator has 50 YES + 50 NO from first mint. Then we gave 30 NO more.
        // Operator: 50 YES, 80 NO. Min = 50. Sweep should merge 50.
        // Actually let's simplify: just give the operator known amounts directly.

        // Reset: use a fresh address to avoid confusion
        address sweeper = address(0xFEE);
        vm.prank(admin);
        exchange.addOperator(sweeper);

        // Mint 100 of each, then distribute: 50 YES + 30 NO to sweeper
        _mintPositionTokens(address(this), 100 * ONE_USDC);
        ctf.safeTransferFrom(address(this), sweeper, yesTokenId, 50 * ONE_USDC, "");
        ctf.safeTransferFrom(address(this), sweeper, noTokenId, 30 * ONE_USDC, "");

        // Sweeper approves exchange for CTF tokens
        vm.prank(sweeper);
        ctf.setApprovalForAll(address(exchange), true);

        uint256 usdcBefore = usdc.balanceOf(sweeper);

        vm.prank(sweeper);
        exchange.sweepFees(yesTokenId);

        // Merged 30 (the minimum), returned 30 USDC collateral
        assertEq(usdc.balanceOf(sweeper), usdcBefore + 30 * ONE_USDC);
        // 20 YES remain (50 - 30), 0 NO remain
        assertEq(ctf.balanceOf(sweeper, yesTokenId), 20 * ONE_USDC);
        assertEq(ctf.balanceOf(sweeper, noTokenId), 0);
    }

    /// @notice sweepFees reverts when the operator has zero of either outcome token.
    function test_SweepFees_RevertsWhenNothingToSweep() public {
        // Operator has no position tokens for this market
        address sweeper = address(0xFEE2);
        vm.prank(admin);
        exchange.addOperator(sweeper);

        vm.prank(sweeper);
        vm.expectRevert(ITradingEE.NothingToSweep.selector);
        exchange.sweepFees(yesTokenId);
    }

    /// @notice Only operators can call sweepFees — non-operators are rejected.
    function test_SweepFees_RevertsForNonOperator() public {
        vm.prank(alice);
        vm.expectRevert(IAuthEE.NotOperator.selector);
        exchange.sweepFees(yesTokenId);
    }

    /// @notice sweepFees emits FeesSwept with the correct operator, tokenId, and amount.
    function test_SweepFees_EmitsFeesSwept() public {
        address sweeper = address(0xFEE3);
        vm.prank(admin);
        exchange.addOperator(sweeper);

        _mintPositionTokens(address(this), 100 * ONE_USDC);
        ctf.safeTransferFrom(address(this), sweeper, yesTokenId, 40 * ONE_USDC, "");
        ctf.safeTransferFrom(address(this), sweeper, noTokenId, 40 * ONE_USDC, "");

        vm.prank(sweeper);
        ctf.setApprovalForAll(address(exchange), true);

        vm.expectEmit(true, true, false, true, address(exchange));
        emit FeesSwept(sweeper, yesTokenId, 40 * ONE_USDC);

        vm.prank(sweeper);
        exchange.sweepFees(yesTokenId);
    }

    // Event mirrored from ProphetCTFExchange for expectEmit matching.
    event FeesSwept(address indexed operator, uint256 indexed tokenId, uint256 amount);
    event ResolutionUpdated(address indexed previousResolution, address indexed newResolution);

    // ── setResolution ────────────────────────────────────────────

    function test_SetResolution_AdminCanUpdate() public {
        address newResolution = address(0xDE50);

        vm.expectEmit(true, true, false, false, address(exchange));
        emit ResolutionUpdated(address(resolution), newResolution);

        vm.prank(admin);
        exchange.setResolution(newResolution);

        assertEq(exchange.resolution(), newResolution);
    }

    function test_SetResolution_RevertsForNonAdmin() public {
        vm.prank(operator);
        vm.expectRevert(IAuthEE.NotAdmin.selector);
        exchange.setResolution(address(0xDE50));
    }

    function test_SetResolution_RevertsOnZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(IAuthEE.ZeroAddress.selector);
        exchange.setResolution(address(0));
    }

    // ── registerToken oracle derivation check ──────────────────────

    /// @notice Conditions prepared directly on the CTF (bypassing Resolution) must
    ///         be rejected. Without this, an attacker could resolve markets without
    ///         cooldown or admin oversight by using their own address as the CTF oracle.
    function test_RegisterToken_RevertsWrongConditionOracle() public {
        address attacker = address(0xBAD);
        bytes32 question2 = keccak256("attacker-question");
        ctf.prepareCondition(attacker, question2, 2);
        bytes32 attackerConditionId = ctf.getConditionId(attacker, question2, 2);

        bytes32 yesCol = ctf.getCollectionId(bytes32(0), attackerConditionId, 1);
        bytes32 noCol = ctf.getCollectionId(bytes32(0), attackerConditionId, 2);
        uint256 yesId = ctf.getPositionId(IERC20(address(usdc)), yesCol);
        uint256 noId = ctf.getPositionId(IERC20(address(usdc)), noCol);

        vm.prank(admin);
        vm.expectRevert(ProphetCTFExchange.WrongConditionOracle.selector);
        exchange.registerToken(yesId, noId, attackerConditionId, question2);
    }

    // ── Helpers ───────────────────────────────────────────────────

    function _createOrder(
        address maker,
        uint256 signerKey,
        uint256 tokenId,
        uint256 makerAmount,
        uint256 takerAmount,
        Side side
    ) internal view returns (Order memory order) {
        order = Order({
            salt: uint256(keccak256(abi.encodePacked(maker, tokenId, makerAmount, block.timestamp))),
            maker: maker,
            signer: maker,
            taker: address(0), // public order
            tokenId: tokenId,
            makerAmount: makerAmount,
            takerAmount: takerAmount,
            expiration: 0, // no expiry
            nonce: 0,
            feeRateBps: 0, // no fees for simpler test assertions
            side: side,
            signatureType: SignatureType.EOA,
            signature: ""
        });

        // Sign the order using EIP-712
        bytes32 orderHash = exchange.hashOrder(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, orderHash);
        order.signature = abi.encodePacked(r, s, v);
    }

    function _approveExchange(address actor) internal {
        vm.prank(actor);
        usdc.approve(address(exchange), type(uint256).max);
    }

    /// @dev Prepares a fresh binary CTF condition via the Resolution wrapper and returns
    ///      its conditionId plus the derived YES/NO position IDs.
    function _prepareCondition(bytes32 question)
        internal
        returns (bytes32 conditionId_, uint256 yesTokenId_, uint256 noTokenId_)
    {
        vm.prank(oracleEoa);
        resolution.prepareCondition(question);
        conditionId_ = ctf.getConditionId(address(resolution), question, 2);

        bytes32 yesCollectionId = ctf.getCollectionId(bytes32(0), conditionId_, 1);
        bytes32 noCollectionId = ctf.getCollectionId(bytes32(0), conditionId_, 2);
        yesTokenId_ = ctf.getPositionId(IERC20(address(usdc)), yesCollectionId);
        noTokenId_ = ctf.getPositionId(IERC20(address(usdc)), noCollectionId);
    }

    /// @dev Mints YES + NO position tokens by splitting USDC through the CTF.
    function _mintPositionTokens(address to, uint256 amount) internal {
        // First ensure the user has USDC and has approved CTF
        vm.startPrank(admin);
        usdc.mint(address(this), amount);
        vm.stopPrank();

        usdc.approve(address(ctf), amount);

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1; // YES
        partition[1] = 2; // NO
        ctf.splitPosition(IERC20(address(usdc)), bytes32(0), conditionId, partition, amount);

        // Transfer position tokens to recipient
        ctf.safeTransferFrom(address(this), to, yesTokenId, amount, "");
        ctf.safeTransferFrom(address(this), to, noTokenId, amount, "");
    }

    /// @dev Required for ERC1155 safe transfers to this test contract.
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }
}
