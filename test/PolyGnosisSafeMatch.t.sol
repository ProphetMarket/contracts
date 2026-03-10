// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Order, Side, SignatureType} from "exchange/libraries/OrderStructs.sol";
import {ISignaturesEE} from "exchange/interfaces/ISignatures.sol";

import {ProphetCTFExchange} from "../src/ProphetCTFExchange.sol";
import {TestUSDC} from "../src/TestUSDC.sol";
import {MockConditionalTokens} from "./mocks/MockConditionalTokens.sol";
import {MockPolySafeFactory} from "./mocks/MockPolySafeFactory.sol";

/// @title PolyGnosisSafeMatchTest
/// @notice Tests matchOrders with signatureType=POLY_GNOSIS_SAFE (2).
///         Verifies the full flow: EOA signs order → maker is derived Safe address →
///         exchange validates signature + address derivation → matchOrders succeeds.
contract PolyGnosisSafeMatchTest is Test {
    ProphetCTFExchange public exchange;
    TestUSDC public usdc;
    MockConditionalTokens public ctf;
    MockPolySafeFactory public safeFactory;

    address public admin;
    uint256 public adminKey;
    address public operatorAddr;
    uint256 public operatorKey;

    // User who signs with POLY_GNOSIS_SAFE
    address public userEoa;
    uint256 public userKey;
    address public userSafe; // derived Safe address

    // House/counterparty uses EOA signature
    address public house;
    uint256 public houseKey;

    bytes32 public questionId = keccak256("Will ETH reach $10k in 2026?");
    bytes32 public conditionId;
    uint256 public yesTokenId;
    uint256 public noTokenId;

    uint256 constant ONE_USDC = 1e6;

    /// @dev A known masterCopy address. Doesn't need real bytecode — the exchange only
    ///      calls masterCopy() on the factory (via PolySafeLib) for address derivation math.
    address constant MOCK_SINGLETON = address(0x5afe5afE5afE5afE5afE5aFe5aFe5Afe5Afe5AfE);

    function setUp() public {
        (admin, adminKey) = makeAddrAndKey("admin");
        (operatorAddr, operatorKey) = makeAddrAndKey("operator");
        (userEoa, userKey) = makeAddrAndKey("user");
        (house, houseKey) = makeAddrAndKey("house");

        vm.startPrank(admin);

        usdc = new TestUSDC(admin);
        ctf = new MockConditionalTokens();

        // Deploy mock Safe factory that returns our known masterCopy
        safeFactory = new MockPolySafeFactory(MOCK_SINGLETON);

        // Deploy exchange with mock Safe factory
        exchange = new ProphetCTFExchange(
            address(usdc),
            address(ctf),
            address(0), // proxyFactory (not used in this test)
            address(safeFactory)
        );

        exchange.addOperator(operatorAddr);

        // Set up a binary market
        ctf.prepareCondition(admin, questionId, 2);
        conditionId = ctf.getConditionId(admin, questionId, 2);

        bytes32 yesCollectionId = ctf.getCollectionId(bytes32(0), conditionId, 1);
        bytes32 noCollectionId = ctf.getCollectionId(bytes32(0), conditionId, 2);
        yesTokenId = ctf.getPositionId(IERC20(address(usdc)), yesCollectionId);
        noTokenId = ctf.getPositionId(IERC20(address(usdc)), noCollectionId);

        exchange.registerToken(yesTokenId, noTokenId, conditionId);
        vm.stopPrank();

        // Derive user's Safe address from the exchange's getSafeAddress()
        userSafe = exchange.getSafeAddress(userEoa);

        // Fund user's Safe with USDC and approve exchange
        vm.prank(admin);
        usdc.mint(userSafe, 10_000 * ONE_USDC);
        vm.prank(userSafe);
        usdc.approve(address(exchange), type(uint256).max);

        // Fund house EOA with USDC and approve exchange
        vm.prank(admin);
        usdc.mint(house, 10_000 * ONE_USDC);
        vm.prank(house);
        usdc.approve(address(exchange), type(uint256).max);

        // Fund operator for filling
        vm.prank(admin);
        usdc.mint(operatorAddr, 10_000 * ONE_USDC);
        vm.prank(operatorAddr);
        usdc.approve(address(exchange), type(uint256).max);
    }

    // ── matchOrders with POLY_GNOSIS_SAFE ────────────────────────────

    function test_MatchOrders_PolyGnosisSafe_BuySide() public {
        // User (Safe): BUY YES at 0.60 (offers 60 USDC for 100 YES)
        // House (EOA): BUY NO at 0.40 (offers 40 USDC for 100 NO)
        // → MINT: 100 USDC → 100 YES + 100 NO
        uint256 userMaker = 60 * ONE_USDC;
        uint256 userTaker = 100 * ONE_USDC;
        uint256 houseMaker = 40 * ONE_USDC;
        uint256 houseTaker = 100 * ONE_USDC;

        Order memory userOrder =
            _createSafeOrder(userEoa, userKey, userSafe, yesTokenId, userMaker, userTaker, Side.BUY);
        Order memory houseOrder = _createEoaOrder(house, houseKey, noTokenId, houseMaker, houseTaker, Side.BUY);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = houseOrder;
        uint256[] memory makerFillAmounts = new uint256[](1);
        makerFillAmounts[0] = houseMaker;

        uint256 safeBefore = usdc.balanceOf(userSafe);
        uint256 houseBefore = usdc.balanceOf(house);

        vm.prank(operatorAddr);
        exchange.matchOrders(userOrder, makerOrders, userMaker, makerFillAmounts);

        // User's Safe paid 60 USDC, received 100 YES tokens (0% fee)
        assertEq(usdc.balanceOf(userSafe), safeBefore - userMaker, "Safe USDC balance mismatch");
        assertEq(ctf.balanceOf(userSafe, yesTokenId), userTaker, "Safe YES token balance mismatch");

        // House paid 40 USDC, received 100 NO tokens (0% fee)
        assertEq(usdc.balanceOf(house), houseBefore - houseMaker, "House USDC balance mismatch");
        assertEq(ctf.balanceOf(house, noTokenId), houseTaker, "House NO token balance mismatch");
    }

    function test_MatchOrders_PolyGnosisSafe_SellSide() public {
        // First: mint position tokens to user's Safe
        _mintPositionTokensTo(userSafe, 100 * ONE_USDC);
        vm.prank(userSafe);
        ctf.setApprovalForAll(address(exchange), true);

        // Also mint to house
        _mintPositionTokensTo(house, 100 * ONE_USDC);
        vm.prank(house);
        ctf.setApprovalForAll(address(exchange), true);

        // User (Safe): SELL YES at 0.60 (offers 100 YES for 60 USDC)
        // House (EOA): SELL NO at 0.40 (offers 100 NO for 40 USDC)
        // → MERGE: 100 YES + 100 NO → 100 USDC
        uint256 userMaker = 100 * ONE_USDC;
        uint256 userTaker = 60 * ONE_USDC;
        uint256 houseMaker = 100 * ONE_USDC;
        uint256 houseTaker = 40 * ONE_USDC;

        Order memory userOrder =
            _createSafeOrder(userEoa, userKey, userSafe, yesTokenId, userMaker, userTaker, Side.SELL);
        Order memory houseOrder = _createEoaOrder(house, houseKey, noTokenId, houseMaker, houseTaker, Side.SELL);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = houseOrder;
        uint256[] memory makerFillAmounts = new uint256[](1);
        makerFillAmounts[0] = houseMaker;

        uint256 safeBefore = usdc.balanceOf(userSafe);
        uint256 houseBefore = usdc.balanceOf(house);

        vm.prank(operatorAddr);
        exchange.matchOrders(userOrder, makerOrders, userMaker, makerFillAmounts);

        // User received 60 USDC, sent 100 YES tokens (0% fee)
        assertEq(usdc.balanceOf(userSafe), safeBefore + userTaker, "Safe USDC balance mismatch");
        assertEq(ctf.balanceOf(userSafe, yesTokenId), 0, "Safe should have no YES tokens left");

        // House received 40 USDC, sent 100 NO tokens (0% fee)
        assertEq(usdc.balanceOf(house), houseBefore + houseTaker, "House USDC balance mismatch");
        assertEq(ctf.balanceOf(house, noTokenId), 0, "House should have no NO tokens left");
    }

    function test_MatchOrders_PolyGnosisSafe_InvalidSignatureReverts() public {
        uint256 userMaker = 60 * ONE_USDC;
        uint256 userTaker = 100 * ONE_USDC;

        // Sign with the WRONG key (house key instead of user key)
        Order memory badOrder =
            _createSafeOrder(userEoa, houseKey, userSafe, yesTokenId, userMaker, userTaker, Side.BUY);

        Order memory houseOrder = _createEoaOrder(house, houseKey, noTokenId, 40 * ONE_USDC, 100 * ONE_USDC, Side.BUY);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = houseOrder;
        uint256[] memory makerFillAmounts = new uint256[](1);
        makerFillAmounts[0] = 40 * ONE_USDC;

        vm.prank(operatorAddr);
        vm.expectRevert(ISignaturesEE.InvalidSignature.selector);
        exchange.matchOrders(badOrder, makerOrders, userMaker, makerFillAmounts);
    }

    function test_MatchOrders_PolyGnosisSafe_WrongSafeMakerReverts() public {
        uint256 userMaker = 60 * ONE_USDC;
        uint256 userTaker = 100 * ONE_USDC;

        // Create order with wrong maker (random address instead of derived Safe)
        address wrongSafe = address(0xDEAD);
        Order memory badOrder =
            _createSafeOrder(userEoa, userKey, wrongSafe, yesTokenId, userMaker, userTaker, Side.BUY);

        Order memory houseOrder = _createEoaOrder(house, houseKey, noTokenId, 40 * ONE_USDC, 100 * ONE_USDC, Side.BUY);

        Order[] memory makerOrders = new Order[](1);
        makerOrders[0] = houseOrder;
        uint256[] memory makerFillAmounts = new uint256[](1);
        makerFillAmounts[0] = 40 * ONE_USDC;

        vm.prank(operatorAddr);
        vm.expectRevert(ISignaturesEE.InvalidSignature.selector);
        exchange.matchOrders(badOrder, makerOrders, userMaker, makerFillAmounts);
    }

    // ── Helpers ──────────────────────────────────────────────────────

    /// @dev Creates an order with signatureType=POLY_GNOSIS_SAFE. The signer is the EOA,
    ///      and the maker is the derived Safe address.
    function _createSafeOrder(
        address signer,
        uint256 signerKey,
        address safeAddr,
        uint256 tokenId,
        uint256 makerAmount,
        uint256 takerAmount,
        Side side
    ) internal view returns (Order memory order) {
        order = Order({
            salt: uint256(keccak256(abi.encodePacked(signer, tokenId, makerAmount, block.timestamp))),
            maker: safeAddr,
            signer: signer,
            taker: address(0),
            tokenId: tokenId,
            makerAmount: makerAmount,
            takerAmount: takerAmount,
            expiration: 0,
            nonce: 0,
            feeRateBps: 0,
            side: side,
            signatureType: SignatureType.POLY_GNOSIS_SAFE,
            signature: ""
        });

        bytes32 orderHash = exchange.hashOrder(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, orderHash);
        order.signature = abi.encodePacked(r, s, v);
    }

    /// @dev Creates an order with signatureType=EOA.
    function _createEoaOrder(
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
            taker: address(0),
            tokenId: tokenId,
            makerAmount: makerAmount,
            takerAmount: takerAmount,
            expiration: 0,
            nonce: 0,
            feeRateBps: 0,
            side: side,
            signatureType: SignatureType.EOA,
            signature: ""
        });

        bytes32 orderHash = exchange.hashOrder(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, orderHash);
        order.signature = abi.encodePacked(r, s, v);
    }

    /// @dev Mints YES + NO position tokens to a recipient.
    function _mintPositionTokensTo(address to, uint256 amount) internal {
        vm.prank(admin);
        usdc.mint(address(this), amount);

        usdc.approve(address(ctf), amount);

        uint256[] memory partition = new uint256[](2);
        partition[0] = 1;
        partition[1] = 2;
        ctf.splitPosition(IERC20(address(usdc)), bytes32(0), conditionId, partition, amount);

        ctf.safeTransferFrom(address(this), to, yesTokenId, amount, "");
        ctf.safeTransferFrom(address(this), to, noTokenId, amount, "");
    }

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
