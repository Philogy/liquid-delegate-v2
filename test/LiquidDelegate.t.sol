// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.17;

import {Test} from "forge-std/Test.sol";
import {ItemType, OrderType, Side} from "seaport/lib/ConsiderationEnums.sol";
import {
    OrderParameters,
    ConsiderationItem,
    OfferItem,
    AdvancedOrder,
    CriteriaResolver,
    Fulfillment,
    FulfillmentComponent
} from "seaport/lib/ConsiderationStructs.sol";
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
        liquidDelegateV2 = new LiquidDelegateV2(address(seaport), address(registry) );
        token = new MockERC721();
    }

    function testWrapOrderFilledByBuyer() public {
        emit log_named_address("address(conduit)", address(conduit));
        emit log_named_address("address(liquidDelegateV2)", address(liquidDelegateV2));

        // Test setup
        User memory seller = user1;
        vm.label(seller.addr, "seller");
        User memory buyer = user2;
        vm.label(buyer.addr, "buyer");

        uint256 expectedETH = 0.3 ether;
        uint256 tokenId = 69;
        token.mint(seller.addr, tokenId);
        vm.prank(seller.addr);
        token.setApprovalForAll(address(conduit), true);

        vm.deal(buyer.addr, expectedETH);

        // Create seller order
        LiquidDelegateV2.ExpiryType expiryType = LiquidDelegateV2.ExpiryType.Relative;
        uint256 expiryValue = 30 days;
        (bytes32 receiptHash,) =
            liquidDelegateV2.getReceiptHash(seller.addr, address(0), address(token), tokenId, expiryType, expiryValue);

        bytes memory receiptSig = signERC712(seller, liquidDelegateV2.DOMAIN_SEPARATOR(), receiptHash);

        AdvancedOrder[] memory orders = new AdvancedOrder[](3);

        orders[0] = _createSellerOrder(seller, tokenId, uint256(receiptHash), expectedETH, true);

        // Create contract order
        orders[1] = _createDelegateContractOrder(
            seller.addr,
            tokenId,
            uint256(receiptHash),
            liquidDelegateV2.getContext(
                LiquidDelegateV2.ReceiptType.DepositorOpen, expiryType, uint80(expiryValue), seller.addr, receiptSig
            )
        );

        // Create buyer order
        orders[2] = _createBuyerOrder(buyer, 0, expectedETH, false);
        orders[2].signature = "";

        // Prepare & execute all orders
        /* CriteriaResolver[] memory criteriaResolvers = new CriteriaResolver[](1);
        criteriaResolvers[0] = CriteriaResolver({
            orderIndex: 2,
            side: Side.CONSIDERATION,
            index: 0


        }); */
        Fulfillment[] memory fulfillments = new Fulfillment[](3);
        // Seller NFT => Liquid Delegate V2
        fulfillments[0] = _constructFulfillment(0, 0, 1, 0);
        // Wrap Receipt => Seller
        fulfillments[1] = _constructFulfillment(1, 0, 0, 1);
        // Buyer ETH => Seller
        fulfillments[2] = _constructFulfillment(2, 0, 0, 0);

        vm.prank(buyer.addr);
        seaport.matchAdvancedOrders{value: expectedETH}(orders, new CriteriaResolver[](0), fulfillments, buyer.addr);
    }

    function testWrapOrderFilledBySeller() public {}

    function _createSellerOrder(
        User memory _user,
        uint256 _tokenId,
        uint256 _receiptId,
        uint256 _expectedETH,
        bool _expectReceipt
    ) internal returns (AdvancedOrder memory) {
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem({
            itemType: ItemType.ERC721,
            token: address(token),
            identifierOrCriteria: _tokenId,
            startAmount: 1,
            endAmount: 1
        });
        uint256 totalConsiders = _expectReceipt ? 2 : 1;
        ConsiderationItem[] memory consideration = new ConsiderationItem[](totalConsiders);
        consideration[0] = ConsiderationItem({
            itemType: ItemType.NATIVE,
            token: address(0),
            identifierOrCriteria: 0,
            startAmount: _expectedETH,
            endAmount: _expectedETH,
            recipient: payable(_user.addr)
        });
        if (_expectReceipt) {
            consideration[1] = ConsiderationItem({
                itemType: ItemType.ERC721,
                token: address(liquidDelegateV2),
                identifierOrCriteria: _receiptId,
                startAmount: 1,
                endAmount: 1,
                recipient: payable(_user.addr)
            });
        }
        OrderParameters memory orderParams = OrderParameters({
            offerer: _user.addr,
            zone: address(0),
            offer: offer,
            consideration: consideration,
            orderType: OrderType.FULL_OPEN,
            startTime: 0,
            endTime: block.timestamp + 3 days,
            zoneHash: bytes32(0),
            salt: 1,
            conduitKey: conduitKey,
            totalOriginalConsiderationItems: totalConsiders
        });
        return AdvancedOrder({
            parameters: orderParams,
            numerator: 1,
            denominator: 1,
            signature: _expectReceipt ? _signOrder(_user, orderParams) : bytes(""),
            extraData: ""
        });
    }

    function _createDelegateContractOrder(
        address _depositor,
        uint256 _tokenId,
        uint256 _receiptId,
        bytes memory _context
    ) internal view returns (AdvancedOrder memory) {
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem({
            itemType: ItemType.ERC721,
            token: address(liquidDelegateV2),
            identifierOrCriteria: _receiptId,
            startAmount: 1,
            endAmount: 1
        });
        ConsiderationItem[] memory consideration = new ConsiderationItem[](1);
        consideration[0] = ConsiderationItem({
            itemType: ItemType.ERC721,
            token: address(token),
            identifierOrCriteria: _tokenId,
            startAmount: 1,
            endAmount: 1,
            recipient: payable(address(liquidDelegateV2))
        });
        OrderParameters memory orderParams = OrderParameters({
            offerer: address(liquidDelegateV2),
            zone: address(0),
            offer: offer,
            consideration: consideration,
            orderType: OrderType.CONTRACT,
            startTime: 0,
            endTime: block.timestamp + 3 days,
            zoneHash: bytes32(0),
            salt: 1,
            conduitKey: conduitKey,
            totalOriginalConsiderationItems: 1
        });
        return
            AdvancedOrder({parameters: orderParams, numerator: 1, denominator: 1, signature: "", extraData: _context});
    }

    function _createBuyerOrder(User memory _user, uint256 _receiptId, uint256 _expectedETH, bool _expectReceipt)
        internal
        returns (AdvancedOrder memory)
    {
        OfferItem[] memory offer = new OfferItem[](1);
        offer[0] = OfferItem({
            itemType: ItemType.NATIVE,
            token: address(0),
            identifierOrCriteria: 0,
            startAmount: _expectedETH,
            endAmount: _expectedETH
        });
        uint256 totalConsiders = _expectReceipt ? 1 : 0;
        ConsiderationItem[] memory consideration = new ConsiderationItem[](totalConsiders);
        /* consideration[0] = ConsiderationItem({
            itemType: ItemType.ERC721_WITH_CRITERIA,
            token: address(liquidDelegateV2),
            identifierOrCriteria: 0,
            startAmount: 1,
            endAmount: 1,
            recipient: payable(_user.addr)
        }); */
        if (_expectReceipt) {
            consideration[0] = ConsiderationItem({
                itemType: ItemType.ERC721,
                token: address(liquidDelegateV2),
                identifierOrCriteria: _receiptId,
                startAmount: 1,
                endAmount: 1,
                recipient: payable(_user.addr)
            });
        }
        OrderParameters memory orderParams = OrderParameters({
            offerer: _user.addr,
            zone: address(0),
            offer: offer,
            consideration: consideration,
            orderType: OrderType.FULL_OPEN,
            startTime: 0,
            endTime: block.timestamp + 3 days,
            zoneHash: bytes32(0),
            salt: 1,
            conduitKey: conduitKey,
            totalOriginalConsiderationItems: totalConsiders
        });
        return AdvancedOrder({
            parameters: orderParams,
            numerator: 1,
            denominator: 1,
            signature: _expectReceipt ? _signOrder(_user, orderParams) : bytes(""),
            extraData: ""
        });
    }

    function _signOrder(User memory _user, OrderParameters memory _params) internal returns (bytes memory) {
        (, bytes32 seaportDomainSeparator,) = seaport.information();
        return signOrder(_user, seaportDomainSeparator, _params, seaport.getCounter(_user.addr));
    }

    function _constructFulfillment(
        uint256 _offerOrderIndex,
        uint256 _offerItemIndex,
        uint256 _considerationOrderIndex,
        uint256 _considerationItemIndex
    ) internal pure returns (Fulfillment memory) {
        FulfillmentComponent[] memory offerComponents = new FulfillmentComponent[](1);
        offerComponents[0] = FulfillmentComponent({orderIndex: _offerOrderIndex, itemIndex: _offerItemIndex});
        FulfillmentComponent[] memory considerationComponents = new FulfillmentComponent[](1);
        considerationComponents[0] =
            FulfillmentComponent({orderIndex: _considerationOrderIndex, itemIndex: _considerationItemIndex});
        return Fulfillment({offerComponents: offerComponents, considerationComponents: considerationComponents});
    }
}
