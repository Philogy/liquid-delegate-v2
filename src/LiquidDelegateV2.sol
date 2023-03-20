// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {
    ContractOffererInterface, ReceivedItem, SpentItem, Schema
} from "seaport/interfaces/ContractOffererInterface.sol";
import {ItemType} from "seaport/lib/ConsiderationEnums.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {EIP712} from "solady/utils/EIP712.sol";
import {SignatureCheckerLib} from "solady/utils/SignatureCheckerLib.sol";
import {IDelegationRegistry} from "./interfaces/IDelegationRegistry.sol";

/// @author philogy <https://github.com/philogy>
/// @dev V2 of Liquid Delegate, also acts as SeaPort Zone
contract LiquidDelegateV2 is ContractOffererInterface, ERC721("LiquidDelegate V2", "RIGHTSV2"), EIP712 {
    enum ReceiptType {
        DepositorOpen,
        RecipientOpen,
        DepositorClosed,
        RecipientClosed
    }

    enum ExpiryType {
        Relative,
        Absolute
    }

    // TODO: Better names for users
    bytes32 internal constant RELATIVE_EXPIRY_TYPE_HASH = keccak256("Relative");
    bytes32 internal constant ABSOLUTE_EXPIRY_TYPE_HASH = keccak256("Absolute");

    struct Rights {
        address tokenContract;
        uint96 expiry;
        uint256 tokenId;
    }

    error InvalidSIP6Version();
    error MissingInToken();
    error InvalidInToken();
    error ReceiptAlreadyInOffer();
    error ExpiryLarger96Bits();
    error EmptyIDTransfer();
    error FailedToWrap();
    error CannotWrapUnowned();
    error NotSeaport();
    error InvalidReceiptType();
    error InvalidExpiryType();
    error InvalidReceiptSignature();
    error ExpiryTimeNotInFuture();

    event WrappedToken(
        uint256 indexed wrappedTokenId, address tokenContract, uint256 tokenId, uint256 expiry, address depositor
    );

    uint256 internal constant EMPTY_RECEIPT_PLACEHOLDER = 1;
    uint256 internal constant LD_SIP_CONTEXT_VERSION = 0x01;

    bytes32 internal constant RECEIPT_TYPE_HASH = keccak256(
        "WrapReceipt(address token,uint256 id,string expiryType,uint256 expiryTime,address depositor,address recipient)"
    );

    uint256 internal validatedReceiptId = EMPTY_RECEIPT_PLACEHOLDER;

    mapping(uint256 => Rights) public idsToRights;

    address public immutable SEAPORT;
    IDelegationRegistry public immutable DELEGATION_REGISTRY;

    constructor(address _SEAPORT, address _DELEGATION_REGISTRY) {
        SEAPORT = _SEAPORT;
        DELEGATION_REGISTRY = IDelegationRegistry(_DELEGATION_REGISTRY);
        (string memory eip712Name,) = _domainNameAndVersion();
        assert(keccak256(bytes(eip712Name)) == keccak256(bytes(name)));
    }

    // TODO: Remove
    function generateOrder(
        address _fulfiller,
        // What LiquidDelegate is giving up
        SpentItem[] calldata,
        // What LiquidDelegate is receiving
        SpentItem[] calldata _inSpends,
        bytes calldata _context // encoded based on the schemaID
    ) external returns (SpentItem[] memory, ReceivedItem[] memory) {
        (
            SpentItem[] memory offer,
            ReceivedItem[] memory consideration,
            address recipient,
            bytes32 validatedReceiptHash,
            address tokenContract,
            uint256 tokenId,
            uint256 expiry,
            address depositor
        ) = _wrapAsOrder(_fulfiller, msg.sender, _inSpends, _context);
        validatedReceiptId = uint256(validatedReceiptHash);

        _mint(recipient, tokenContract, tokenId, expiry, depositor);

        return (offer, consideration);
    }

    function ratifyOrder(
        SpentItem[] calldata,
        ReceivedItem[] calldata,
        bytes calldata, // encoded based on the schemaID
        bytes32[] calldata,
        uint256
    ) external returns (bytes4) {
        // Reset receipt incase it wasn't used.
        validatedReceiptId = EMPTY_RECEIPT_PLACEHOLDER;
        return this.ratifyOrder.selector;
    }

    function previewOrder(
        address _caller,
        address _fulfiller,
        // What LiquidDelegate is giving up
        SpentItem[] calldata,
        // What LiquidDelegate is receiving
        SpentItem[] calldata _inSpends,
        bytes calldata _context // encoded based on the schemaID
    ) public view returns (SpentItem[] memory offer, ReceivedItem[] memory consideration) {
        (offer, consideration,,,,,,) = _wrapAsOrder(_fulfiller, _caller, _inSpends, _context);
    }

    function getSeaportMetadata() external pure returns (string memory, Schema[] memory) {
        Schema[] memory schemas = new Schema[](0);
        return ("Liquid Delegate V2", schemas);
    }

    function transferFrom(address _from, address _to, uint256 _tokenId) public override {
        if (_from == address(this)) {
            if (_tokenId == EMPTY_RECEIPT_PLACEHOLDER) revert EmptyIDTransfer();

            if (_tokenId == validatedReceiptId) {
                validatedReceiptId = EMPTY_RECEIPT_PLACEHOLDER;
                return;
            }
        }

        super.transferFrom(_from, _to, _tokenId);

        Rights memory rights = idsToRights[_tokenId];
        DELEGATION_REGISTRY.delegateForToken(_from, rights.tokenContract, rights.tokenId, false);
        DELEGATION_REGISTRY.delegateForToken(_to, rights.tokenContract, rights.tokenId, true);
    }

    function tokenURI(uint256) public view override returns (string memory) {
        balanceOf(address(0));
        return "";
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    function _mint(address _recipient, address _tokenContract, uint256 _tokenId, uint256 _expiry, address _depositor)
        internal
    {
        uint256 wrappedTokenId = uint256(keccak256(abi.encode(_tokenContract, _tokenId, _expiry, _depositor)));

        idsToRights[wrappedTokenId] =
            Rights({tokenContract: _tokenContract, expiry: uint96(_expiry), tokenId: _tokenId});

        _mint(_recipient, wrappedTokenId);
        emit WrappedToken(wrappedTokenId, _tokenContract, _tokenId, _expiry, _depositor);
    }

    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("LiquidDelegate V2", "1.0");
    }

    function _wrapAsOrder(address _fulfiller, address _caller, SpentItem[] calldata _inSpends, bytes calldata _context)
        internal
        view
        returns (
            SpentItem[] memory offer,
            ReceivedItem[] memory consideration,
            address recipient,
            bytes32 receiptHash,
            address tokenContract,
            uint256 tokenId,
            uint256 expiry,
            address depositor
        )
    {
        if (_caller != address(SEAPORT)) revert NotSeaport();

        // Get token to be wrapped
        if (_inSpends.length == 0) revert MissingInToken();
        SpentItem calldata inItem = _inSpends[0];
        if (inItem.amount != 1 || inItem.itemType != ItemType.ERC721) revert InvalidInToken();
        tokenContract = inItem.token;
        tokenId = inItem.identifier;

        (receiptHash, depositor, recipient, expiry) =
            _validateAndExtractContext(_fulfiller, tokenContract, tokenId, _context);

        offer = new SpentItem[](1);
        offer[0] =
            SpentItem({itemType: ItemType.ERC721, token: address(this), identifier: uint256(receiptHash), amount: 1});

        consideration = new ReceivedItem[](1);
        consideration[0] = ReceivedItem({
            itemType: ItemType.ERC721,
            token: tokenContract,
            identifier: tokenId,
            amount: 1,
            recipient: payable(address(this))
        });
    }

    function getContext(
        ReceiptType _receiptType,
        ExpiryType _expiryType,
        uint80 _expiryValue,
        address _actor,
        bytes calldata _sig
    ) public pure returns (bytes memory) {
        bytes32 packedData = bytes32(abi.encodePacked(_receiptType, _expiryType, _expiryValue, _actor));
        return abi.encodePacked(uint8(LD_SIP_CONTEXT_VERSION), abi.encode(packedData, _sig));
    }

    /// @dev Builds unique ERC-712 struct hash
    function getReceiptHash(
        address _depositor,
        address _recipient,
        address _token,
        uint256 _id,
        ExpiryType _expiryType,
        uint256 _expiryValue
    ) public view returns (bytes32 receiptHash, uint256 expiryTimestamp) {
        bytes32 expiryTypeHash;
        if (_expiryType == ExpiryType.Relative) {
            expiryTypeHash = RELATIVE_EXPIRY_TYPE_HASH;
            expiryTimestamp = block.timestamp + _expiryValue;
        } else if (_expiryType == ExpiryType.Absolute) {
            expiryTypeHash = ABSOLUTE_EXPIRY_TYPE_HASH;
        } else {
            // Incase another enum type accidentally added
            revert InvalidExpiryType();
        }

        receiptHash =
            keccak256(abi.encode(RECEIPT_TYPE_HASH, _token, _id, expiryTypeHash, _expiryValue, _depositor, _recipient));
    }

    function _validateAndExtractContext(address _fulfiller, address _token, uint256 _id, bytes calldata _context)
        internal
        view
        returns (bytes32 receiptHash, address depositor, address recipient, uint256 expiry)
    {
        // Load and check SIP-6 version byte
        uint256 versionByte;
        assembly {
            versionByte := byte(0, calldataload(_context.offset))
        }
        if (versionByte != LD_SIP_CONTEXT_VERSION) revert InvalidSIP6Version();
        // Decode context
        (bytes32 packedData, bytes memory sig) = abi.decode(_context[1:], (bytes32, bytes));
        ReceiptType receiptType;
        ExpiryType expiryType;
        uint256 expiryValue;
        address actor;
        assembly {
            // receiptType = packedData[0:1]
            receiptType := byte(0, packedData)
            // expiryType = packedData[1:2]
            expiryType := byte(1, packedData)
            // expiryValue = packedData[2:12]
            expiryValue := and(shr(160, packedData), 0xffffffffffffffffffff)
            // actor = packedData[12:32]
            // Leave upper bits dirty, Solidity/Solady will clean.
            // Solady.SignatureCheckerLib will return false if actor == 0.
            actor := packedData
        }

        // Verify actor signature.
        {
            address commitedDepositor;
            address commitedRecipient;

            if (receiptType == ReceiptType.DepositorOpen) {
                commitedDepositor = actor;
                depositor = actor;
                recipient = _fulfiller;
            } else if (receiptType == ReceiptType.RecipientOpen) {
                commitedRecipient = actor;
                depositor = _fulfiller;
                recipient = actor;
            } else if (receiptType == ReceiptType.DepositorClosed) {
                commitedDepositor = actor;
                commitedRecipient = _fulfiller;
                depositor = actor;
                recipient = _fulfiller;
            } else if (receiptType == ReceiptType.RecipientClosed) {
                commitedDepositor = _fulfiller;
                commitedRecipient = actor;
                depositor = _fulfiller;
                recipient = actor;
            } else {
                // Incase another enum type accidentally added
                revert InvalidReceiptType();
            }

            // Require signed receipt to make sure users see receipt parameters when creating order.
            (receiptHash, expiry) =
                getReceiptHash(commitedDepositor, commitedRecipient, _token, _id, expiryType, expiryValue);

            if (!SignatureCheckerLib.isValidSignatureNow(actor, _hashTypedData(receiptHash), sig)) {
                revert InvalidReceiptSignature();
            }
        }

        if (block.timestamp >= expiry) revert ExpiryTimeNotInFuture();
    }
}
