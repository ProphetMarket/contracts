// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Order, Side, SignatureType} from "exchange/libraries/OrderStructs.sol";
import {IAuthEE} from "exchange/interfaces/IAuth.sol";
import {ITradingEE} from "exchange/interfaces/ITrading.sol";
import {IPausableEE} from "exchange/interfaces/IPausable.sol";

import {ProphetCTFExchange} from "../src/ProphetCTFExchange.sol";
import {TestUSDC} from "../src/TestUSDC.sol";
import {MockConditionalTokens} from "./mocks/MockConditionalTokens.sol";

contract CTFExchangeTest is Test {
    ProphetCTFExchange public exchange;
    TestUSDC public usdc;
    MockConditionalTokens public ctf;

    // Test actors
    address public admin;
    uint256 public adminKey;
    address public operator;
    uint256 public operatorKey;
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
        (alice, aliceKey) = makeAddrAndKey("alice");
        (bob, bobKey) = makeAddrAndKey("bob");

        // Deploy contracts
        vm.startPrank(admin);
        usdc = new TestUSDC(admin);
        ctf = new MockConditionalTokens();

        // Deploy exchange: admin becomes admin + operator automatically
        exchange = new ProphetCTFExchange(
            address(usdc),
            address(ctf),
            address(0), // proxyFactory (not needed for EOA tests)
            address(0) // safeFactory (not needed for EOA tests)
        );

        // Add operator role
        exchange.addOperator(operator);

        // Prepare a condition (binary market: YES/NO)
        address oracle = admin; // admin acts as oracle for tests
        ctf.prepareCondition(oracle, questionId, 2);
        conditionId = ctf.getConditionId(oracle, questionId, 2);

        // Compute position token IDs (matching Gnosis CTF spec)
        bytes32 yesCollectionId = ctf.getCollectionId(bytes32(0), conditionId, 1); // indexSet 1 = YES
        bytes32 noCollectionId = ctf.getCollectionId(bytes32(0), conditionId, 2); // indexSet 2 = NO
        yesTokenId = ctf.getPositionId(IERC20(address(usdc)), yesCollectionId);
        noTokenId = ctf.getPositionId(IERC20(address(usdc)), noCollectionId);

        // Register token pair on exchange
        exchange.registerToken(yesTokenId, noTokenId, conditionId);

        vm.stopPrank();

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

    function test_RegisterToken_OperatorCanCall() public {
        // Create a second condition so we have new token IDs to register
        bytes32 questionId2 = keccak256("Will BTC reach $200k in 2026?");
        address oracle = admin;
        ctf.prepareCondition(oracle, questionId2, 2);
        bytes32 conditionId2 = ctf.getConditionId(oracle, questionId2, 2);

        bytes32 yesCollectionId2 = ctf.getCollectionId(bytes32(0), conditionId2, 1);
        bytes32 noCollectionId2 = ctf.getCollectionId(bytes32(0), conditionId2, 2);
        uint256 yesTokenId2 = ctf.getPositionId(IERC20(address(usdc)), yesCollectionId2);
        uint256 noTokenId2 = ctf.getPositionId(IERC20(address(usdc)), noCollectionId2);

        // Operator (not admin) registers the token pair
        vm.prank(operator);
        exchange.registerToken(yesTokenId2, noTokenId2, conditionId2);

        assertEq(exchange.getConditionId(yesTokenId2), conditionId2);
        assertEq(exchange.getComplement(yesTokenId2), noTokenId2);
        assertEq(exchange.getComplement(noTokenId2), yesTokenId2);
    }

    function test_RegisterToken_AdminCanCall() public {
        // Admin registers a new token pair (existing behavior)
        bytes32 questionId2 = keccak256("Will SOL reach $1k in 2026?");
        address oracle = admin;
        ctf.prepareCondition(oracle, questionId2, 2);
        bytes32 conditionId2 = ctf.getConditionId(oracle, questionId2, 2);

        bytes32 yesCollectionId2 = ctf.getCollectionId(bytes32(0), conditionId2, 1);
        bytes32 noCollectionId2 = ctf.getCollectionId(bytes32(0), conditionId2, 2);
        uint256 yesTokenId2 = ctf.getPositionId(IERC20(address(usdc)), yesCollectionId2);
        uint256 noTokenId2 = ctf.getPositionId(IERC20(address(usdc)), noCollectionId2);

        vm.prank(admin);
        exchange.registerToken(yesTokenId2, noTokenId2, conditionId2);

        assertEq(exchange.getConditionId(yesTokenId2), conditionId2);
        assertEq(exchange.getComplement(yesTokenId2), noTokenId2);
    }

    function test_RegisterToken_RevertsForNonAdminNonOperator() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(ProphetCTFExchange.NotAdminOrOperator.selector);
        exchange.registerToken(123, 456, bytes32(uint256(789)));
    }

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
