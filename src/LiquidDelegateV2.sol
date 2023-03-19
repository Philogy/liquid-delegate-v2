// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {
    ContractOffererInterface, ReceivedItem, SpentItem, Schema
} from "seaport/interfaces/ContractOffererInterface.sol";
import {ItemType} from "seaport/lib/ConsiderationEnums.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {EIP712} from "solady/utils/EIP712.sol";
import {IDelegationRegistry} from "./interfaces/IDelegationRegistry.sol";

/// @author philogy <https://github.com/philogy>
/// @dev V2 of Liquid Delegate, also acts as SeaPort Zone
contract LiquidDelegateV2 is ContractOffererInterface, ERC721("LiquidDelegate V2", "RIGHTSV2"), EIP712 {
    enum ReceiptType {
        Depositor,
        Recipient
    }

    enum ExpiryType {
        Relative,
        Absolute
    }

    struct Rights {
        address contract_;
        uint96 expiry;
        uint256 tokenId;
    }

    error InvalidContextSize();
    error InvalidSIP6Version();
    error MissingInToken();
    error InvalidInToken();
    error ReceiptAlreadyInOffer();
    error ExpiryLarger96Bits();
    error EmptyID();
    error FailedToWrap();
    error CannotWrapUnowned();
    error NotSeaport();

    uint256 internal constant EMPTY_ID_PLACEHOLDER = 1;
    uint256 internal constant LD_SIP_CONTEXT_VERSION = 0xff;

    uint256 internal newWrappedTokenId = EMPTY_ID_PLACEHOLDER;
    uint256 internal validatedReceiptId = EMPTY_ID_PLACEHOLDER;

    mapping(uint256 => Rights) public idsToRights;

    address public immutable SEAPORT;
    IDelegationRegistry public immutable DELEGATION_REGISTRY;

    constructor(address _SEAPORT, address _DELEGATION_REGISTRY) {
        SEAPORT = _SEAPORT;
        DELEGATION_REGISTRY = IDelegationRegistry(_DELEGATION_REGISTRY);
        (string memory eip712Name, ) = _domainNameAndVersion();
        assert(keccak256(bytes(eip712Name)) == keccak256(bytes(name)));
    }

    // TODO: Remove
    function generateOrder(
        address,
        // What LiquidDelegate is giving up
        SpentItem[] calldata,
        // What LiquidDelegate is receiving
        SpentItem[] calldata _inSpends,
        bytes calldata _context // encoded based on the schemaID
    ) external returns (SpentItem[] memory offer, ReceivedItem[] memory consideration) {
        address contract_;
        uint256 tokenId;
        uint256 expiry;
        uint256 wrappedTokenId;
        (offer, consideration, wrappedTokenId, validatedReceiptId, contract_, tokenId, expiry) =
            _wrapAsOrder(msg.sender, _inSpends, _context);
        idsToRights[wrappedTokenId] = Rights({contract_: contract_, expiry: uint96(expiry), tokenId: tokenId});
        newWrappedTokenId = wrappedTokenId;
    }

    function ratifyOrder(
        SpentItem[] calldata,
        ReceivedItem[] calldata,
        bytes calldata, // encoded based on the schemaID
        bytes32[] calldata,
        uint256
    ) external returns (bytes4) {
        // Reset receipt incase it wasn't required.
        validatedReceiptId = EMPTY_ID_PLACEHOLDER;
        if (newWrappedTokenId != EMPTY_ID_PLACEHOLDER) revert FailedToWrap();
        return this.ratifyOrder.selector;
    }

    function previewOrder(
        address _caller,
        address,
        // What LiquidDelegate is giving up
        SpentItem[] calldata,
        // What LiquidDelegate is receiving
        SpentItem[] calldata _inSpends,
        bytes calldata _context // encoded based on the schemaID
    ) public view returns (SpentItem[] memory offer, ReceivedItem[] memory consideration) {
        (offer, consideration,,,,,) = _wrapAsOrder(_caller, _inSpends, _context);
    }

    function getSeaportMetadata() external pure returns (string memory, Schema[] memory) {
        Schema[] memory schemas = new Schema[](0);
        return ("Liquid Delegate V2", schemas);
    }

    function transferFrom(address _from, address _to, uint256 _tokenId) public override {
        if (_from == address(this)) {
            if (_tokenId == EMPTY_ID_PLACEHOLDER) revert EmptyID();

            if (_tokenId == newWrappedTokenId) {
                Rights memory rights = idsToRights[_tokenId];
                DELEGATION_REGISTRY.delegateForToken(_to, rights.contract_, rights.tokenId, true);
                if (ERC721(rights.contract_).ownerOf(rights.tokenId) != address(this)) revert CannotWrapUnowned();
                _mint(_to, _tokenId);
                newWrappedTokenId = EMPTY_ID_PLACEHOLDER;
            } else if (_tokenId == validatedReceiptId) {
                validatedReceiptId = EMPTY_ID_PLACEHOLDER;
            }

            return;
        }

        Rights memory rights = idsToRights[_tokenId];
        DELEGATION_REGISTRY.delegateForToken(_from, rights.contract_, rights.tokenId, false);
        DELEGATION_REGISTRY.delegateForToken(_to, rights.contract_, rights.tokenId, true);

        super.transferFrom(_from, _to, _tokenId);
    }

    function tokenURI(uint256) public view override returns (string memory) {
        return "";
    }

    function getReceiptId(
        address _contract,
        uint256 _tokenId,
        ExpiryType _expiryType,
        uint256 _expiryTime,
        address _depositor
    ) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(_contract, _tokenId, _expiryType, _expiryTime, _depositor)));
    }

    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return ("LiquidDelegate V2", "1.0");
    }

    function _wrapAsOrder(address _caller, SpentItem[] calldata _inSpends, bytes calldata _context)
        internal
        view
        returns (
            SpentItem[] memory offer,
            ReceivedItem[] memory consideration,
            uint256 ldTokenId,
            uint256 receiptId,
            address contract_,
            uint256 tokenId,
            uint256 expiry
        )
    {
        if (_caller != address(SEAPORT)) revert NotSeaport();

        (ExpiryType expiryType, uint256 expiryTime, address depositor) = _decodeContext(_context);
        expiry = expiryType == ExpiryType.Relative ? block.timestamp + expiryTime : expiryTime;
        if (expiry > type(uint96).max) revert ExpiryLarger96Bits();

        // Valid token to be wrapped
        if (_inSpends.length == 0) revert MissingInToken();
        SpentItem calldata inItem = _inSpends[0];
        if (inItem.amount != 1 || inItem.itemType != ItemType.ERC721) revert InvalidInToken();
        contract_ = inItem.token;
        tokenId = inItem.identifier;

        ldTokenId = uint256(keccak256(abi.encode(contract_, tokenId, expiry, depositor)));
        receiptId = getReceiptId(contract_, tokenId, expiryType, expiryTime, depositor);

        offer = new SpentItem[](2);
        offer[0] = SpentItem({itemType: ItemType.ERC721, token: address(this), identifier: ldTokenId, amount: 1});
        offer[1] = SpentItem({itemType: ItemType.ERC721, token: address(this), identifier: receiptId, amount: 1});

        consideration = new ReceivedItem[](1);
        consideration[0] = ReceivedItem({
            itemType: ItemType.ERC721,
            token: contract_,
            identifier: tokenId,
            amount: 1,
            recipient: payable(address(this))
        });
    }

    function _decodeContext(bytes calldata _context) internal pure returns (ExpiryType, uint256, address) {
        if (_context.length != 0x20 * 3 + 1) revert InvalidContextSize();
        uint256 versionByte;
        ReceiptType receiptType;
        assembly {
            versionByte := shr(248, calldataload(_context.offset))
        }
        /* if (versionByte != LD_SIP_CONTEXT_VERSION) revert InvalidSIP6Version(); */
        if (versionByte != 0x01) revert InvalidSIP6Version();
        return abi.decode(_context[1:], (ExpiryType, uint256, address));
    }
}
