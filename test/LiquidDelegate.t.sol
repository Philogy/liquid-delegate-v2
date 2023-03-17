// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import {Test} from "forge-std/Test.sol";
import {ItemType, OrderType} from "seaport/lib/ConsiderationEnums.sol";
import {OrderParameters, ConsiderationItem, OfferItem, Order} from "seaport/lib/ConsiderationStructs.sol";
import {LiquidDelegateV2} from "src/LiquidDelegateV2.sol";
import {DelegationRegistry} from "src/DelegationRegistry.sol";
import {BaseSeaportTest} from "./base/BaseSeaportTest.sol";
import {SeaportHelpers, User} from "./utils/SeaportHelpers.sol";
import {MockERC721} from "./mock/MockERC721.sol";

contract LiquidDelegateTest is Test, BaseSeaportTest, SeaportHelpers {
    LiquidDelegateV2 liquidDelegateV2;
    DelegationRegistry registry;

    MockERC721 token;

    User user1 = makeUser("user1");
    User user2 = makeUser("user2");
    User user3 = makeUser("user3");

    function setUp() public {
        registry = new DelegationRegistry();
        liquidDelegateV2 = new LiquidDelegateV2(address(registry), address(seaport));
        token = new MockERC721();
    }

    function testWrapOrderFilledByBuyer() public {
        // Test setup
        User memory seller = user1;
        uint256 tokenId = 1;
        token.mint(seller.addr, tokenId);
        vm.prank(seller.addr);
        token.setApprovalForAll(address(conduit), true);

        // Create seller order
        uint256 expectedETH = 0.3 ether;
        ConsiderationItem[] memory sellerConsideration = new ConsiderationItem[](2);
        sellerConsideration[0] = ConsiderationItem({
            itemType: ItemType.NATIVE,
            token: address(0),
            identifierOrCriteria: 0,
            startAmount: expectedETH,
            endAmount: expectedETH,
            recipient: payable(seller.addr)
        });
        uint256 receiptId = liquidDelegateV2.getReceiptId(
            address(token), tokenId, LiquidDelegateV2.ExpiryType.Relative, 30 days, seller.addr
        );
        sellerConsideration[1] = ConsiderationItem({
            itemType: ItemType.ERC721,
            token: address(liquidDelegateV2),
            identifierOrCriteria: receiptId,
            startAmount: 1,
            endAmount: 1,
            recipient: payable(seller.addr)
        });
        OfferItem[] memory sellerOffer = new OfferItem[](1);
        sellerOffer[0] = OfferItem({
            itemType: ItemType.ERC721,
            token: address(token),
            identifierOrCriteria: tokenId,
            startAmount: 1,
            endAmount: 1
        });
        OrderParameters memory sellerOrderParams = OrderParameters({
            offerer: seller.addr,
            zone: address(0),
            offer: sellerOffer,
            consideration: sellerConsideration,
            orderType: OrderType.FULL_OPEN,
            startTime: 0,
            endTime: block.timestamp + 3 days,
            zoneHash: bytes32(0),
            salt: uint256(keccak256("testWrapOrderFilledBySeller.seller.salt")),
            conduitKey: conduitKey,
            totalOriginalConsiderationItems: 2
        });
        (, bytes32 seaportDomainSeparator,) = seaport.information();
        bytes memory sellerSignature =
            signOrder(seller, seaportDomainSeparator, sellerOrderParams, seaport.getCounter(seller.addr));

        // Prepare contract order
    }

    function testWrapOrderFilledBySeller() public {}
}
