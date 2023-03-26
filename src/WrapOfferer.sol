// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {EIP712} from "solady/utils/EIP712.sol";
import {IWrapOfferer} from "./interfaces/IWrapOfferer.sol";

import {SignatureCheckerLib} from "solady/utils/SignatureCheckerLib.sol";
import {ReceivedItem, SpentItem, Schema} from "seaport/interfaces/ContractOffererInterface.sol";
import {ItemType} from "seaport/lib/ConsiderationEnums.sol";

import {ILiquidDelegateV2, ExpiryType} from "./interfaces/ILiquidDelegateV2.sol";

/// @author philogy <https://github.com/philogy>
contract WrapOfferer is IWrapOfferer, EIP712 {
    bytes32 internal constant RELATIVE_EXPIRY_TYPE_HASH = keccak256("Relative");
    bytes32 internal constant ABSOLUTE_EXPIRY_TYPE_HASH = keccak256("Absolute");

    error NotSeaport();
    error EmptyReceived();
    error IncorrectReceived();
    error InvalidExpiryType();
    error InvalidSignature();
    error InvalidReceiptTransfer();
    error InvalidReceiptId();

    uint256 internal constant EMPTY_RECEIPT_PLACEHOLDER = 1;

    uint256 internal constant RECEIPT_SIDE_BIT = 1;
    uint256 internal constant RECEIPT_SIDE_DELEGATE = 1;
    uint256 internal constant RECEIPT_SIDE_PRINCIPAL = 0;

    uint256 internal constant RECEIPT_MATCH_BIT = 0;
    uint256 internal constant RECEIPT_MATCH_OPEN = 1;
    uint256 internal constant RECEIPT_MATCH_CLOSED = 0;

    bytes32 internal constant RECEIPT_TYPE_HASH = keccak256(
        "WrapReceipt(address token,uint256 id,string expiryType,uint256 expiryTime,address delegateRecipient,address principalRecipient)"
    );

    address public immutable SEAPORT;
    address public immutable LIQUID_DELEGATE;

    uint256 internal $validatedReceiptId = EMPTY_RECEIPT_PLACEHOLDER;

    constructor(address _SEAPORT, address _LQUID_DELEGATE) {
        SEAPORT = _SEAPORT;
        LIQUID_DELEGATE = _LQUID_DELEGATE;
    }

    function generateOrder(
        address,
        // What LiquidDelegate is giving up
        SpentItem[] calldata minimumOut,
        // What LiquidDelegate is receiving
        SpentItem[] calldata maximumReceived,
        bytes calldata context // encoded based on the schemaID
    ) external returns (SpentItem[] memory, ReceivedItem[] memory) {
        (SpentItem[] memory offer, ReceivedItem[] memory consideration, bytes32 validatedReceiptHash) =
            _wrapAsOrder(msg.sender, minimumOut.length, maximumReceived, context);
        $validatedReceiptId = uint256(validatedReceiptHash);

        return (offer, consideration);
    }

    function ratifyOrder(
        SpentItem[] calldata inSpends,
        ReceivedItem[] calldata,
        bytes calldata context, // encoded based on the schemaID
        bytes32[] calldata,
        uint256
    ) external returns (bytes4) {
        if (msg.sender != SEAPORT) revert NotSeaport();

        (, ExpiryType expiryType, uint40 expiryValue, address delegateRecipient, address principalRecipient,) =
            _decodeContext(context);
        (address tokenContract, uint256 tokenId) = _getTokenFromSpends(inSpends);

        // Remove validated receipt
        $validatedReceiptId = EMPTY_RECEIPT_PLACEHOLDER;

        // `LiquidDelegateV2.mint` checks whether the appropriate NFT has been deposited.
        ILiquidDelegateV2(LIQUID_DELEGATE).mint(
            delegateRecipient, principalRecipient, tokenContract, tokenId, expiryType, expiryValue
        );

        return this.ratifyOrder.selector;
    }

    function previewOrder(
        address caller,
        address,
        // What LiquidDelegate is giving up
        SpentItem[] calldata minimumReceived,
        // What LiquidDelegate is receiving
        SpentItem[] calldata maximumSpent,
        bytes calldata context // encoded based on the schemaID
    ) public view returns (SpentItem[] memory offer, ReceivedItem[] memory consideration) {
        (offer, consideration,) = _wrapAsOrder(caller, minimumReceived.length, maximumSpent, context);
    }

    function getSeaportMetadata() external pure returns (string memory, Schema[] memory) {
        return (name(), new Schema[](0));
    }

    // /// @dev Builds unique ERC-712 struct hash
    function getReceiptHash(
        address delegateRecipient,
        address principalRecipient,
        address token,
        uint256 id,
        ExpiryType expiryType,
        uint256 expiryValue
    ) public pure returns (bytes32 receiptHash) {
        bytes32 expiryTypeHash;
        if (expiryType == ExpiryType.Relative) {
            expiryTypeHash = RELATIVE_EXPIRY_TYPE_HASH;
        } else if (expiryType == ExpiryType.Absolute) {
            expiryTypeHash = ABSOLUTE_EXPIRY_TYPE_HASH;
        } else {
            // Incase another enum type accidentally added
            revert InvalidExpiryType();
        }

        receiptHash = keccak256(
            abi.encode(RECEIPT_TYPE_HASH, token, id, expiryTypeHash, expiryValue, delegateRecipient, principalRecipient)
        );
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    function name() public pure returns (string memory) {
        return "Liquid Delegate V2 Seaport Offerer";
    }

    function transferFrom(address from, address, uint256 id) public view {
        if (from != address(this) || id == EMPTY_RECEIPT_PLACEHOLDER) revert InvalidReceiptTransfer();
        if (id != $validatedReceiptId) revert InvalidReceiptId();
    }

    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return (name(), "1");
    }

    function _wrapAsOrder(address caller, uint256 receiptCount, SpentItem[] calldata inSpends, bytes calldata context)
        internal
        view
        returns (SpentItem[] memory offer, ReceivedItem[] memory consideration, bytes32 receiptHash)
    {
        if (caller != SEAPORT) revert NotSeaport();

        // Get token to be wrapped
        (address tokenContract, uint256 tokenId) = _getTokenFromSpends(inSpends);

        receiptHash = _validateAndExtractReceipt(tokenContract, tokenId, context);

        // Issue as many receipts as requested, should just be 1 in most cases.
        offer = new SpentItem[](receiptCount);
        for (uint256 i; i < receiptCount;) {
            offer[i] = SpentItem({
                itemType: ItemType.ERC721,
                token: address(this),
                identifier: uint256(receiptHash),
                amount: 1
            });
            unchecked {
                ++i;
            }
        }

        consideration = new ReceivedItem[](1);
        consideration[0] = ReceivedItem({
            itemType: ItemType.ERC721,
            token: tokenContract,
            identifier: tokenId,
            amount: 1,
            recipient: payable(LIQUID_DELEGATE)
        });
    }

    function _getTokenFromSpends(SpentItem[] calldata inSpends) internal pure returns (address, uint256) {
        if (inSpends.length == 0) revert EmptyReceived();
        SpentItem calldata inItem = inSpends[0];
        if (inItem.amount != 1 || inItem.itemType != ItemType.ERC721) revert IncorrectReceived();
        return (inItem.token, inItem.identifier);
    }

    function _validateAndExtractReceipt(address token, uint256 id, bytes calldata context)
        internal
        view
        returns (bytes32 receiptHash)
    {
        (
            uint256 controlBits,
            ExpiryType expiryType,
            uint40 expiryValue,
            address delegateRecipient,
            address principalRecipient,
            bytes memory signature
        ) = _decodeContext(context);

        bool delegateSigning = (controlBits >> RECEIPT_SIDE_BIT) & 1 == RECEIPT_SIDE_DELEGATE;
        bool matchClosed = (controlBits >> RECEIPT_MATCH_BIT) & 1 == RECEIPT_MATCH_CLOSED;

        address signer = delegateSigning ? delegateRecipient : principalRecipient;

        // Check signature
        receiptHash = getReceiptHash(
            matchClosed || delegateSigning ? delegateRecipient : address(0),
            matchClosed || !delegateSigning ? principalRecipient : address(0),
            token,
            id,
            expiryType,
            expiryValue
        );
        // `isValidSignatureNow` returns `false` if `signer` is `address(0)`.
        if (!SignatureCheckerLib.isValidSignatureNow(signer, _hashTypedData(receiptHash), signature)) {
            revert InvalidSignature();
        }
    }

    function _decodeContext(bytes calldata context)
        internal
        pure
        returns (
            uint256 controlBits,
            ExpiryType expiryType,
            uint40 expiryValue,
            address delegateRecipient,
            address principalRecipient,
            bytes memory signature
        )
    {
        controlBits;
        assembly {
            controlBits := and(byte(0, calldataload(context.offset)), 3)
        }

        (expiryType, expiryValue, delegateRecipient, principalRecipient, signature) =
            abi.decode(context[1:], (ExpiryType, uint40, address, address, bytes));
    }
}
