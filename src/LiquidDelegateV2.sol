// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {BaseERC721} from "./lib/BaseERC721.sol";
import {EIP712} from "solady/utils/EIP712.sol";
import {Multicallable} from "solady/utils/Multicallable.sol";
import {LDMetadataManager} from "./LDMetadataManager.sol";

import {SignatureCheckerLib} from "solady/utils/SignatureCheckerLib.sol";
import {
    ContractOffererInterface, ReceivedItem, SpentItem, Schema
} from "seaport/interfaces/ContractOffererInterface.sol";
import {ItemType} from "seaport/lib/ConsiderationEnums.sol";

import {IDelegationRegistry} from "./interfaces/IDelegationRegistry.sol";
import {PrincipalToken} from "./PrincipalToken.sol";

/// @author philogy <https://github.com/philogy>
/// @dev V2 of Liquid Delegate, also acts as SeaPort Zone
contract LiquidDelegateV2 is ContractOffererInterface, BaseERC721, EIP712, Multicallable, LDMetadataManager {
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
        uint40 expiry;
        uint56 nonce;
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
    error InvalidSignature();
    error ExpiryTimeNotInFuture();

    error WithdrawNotAvailable();

    event TokenWrapped(address tokenContract, uint256 tokenId, uint256 expiry);

    uint256 internal constant EMPTY_RECEIPT_PLACEHOLDER = 1;
    uint256 internal constant LD_SIP_CONTEXT_VERSION = 0x01;

    uint256 internal constant BASE_RIGHTS_ID_MASK = 0xffffffffffffffffffffffffffffffffffffffffffffffffff00000000000000;
    uint256 internal constant RIGHTS_ID_NONCE_BITSIZE = 56;

    bytes32 internal constant RECEIPT_TYPE_HASH = keccak256(
        "WrapReceipt(address token,uint256 id,string expiryType,uint256 expiryTime,address depositor,address recipient)"
    );
    bytes32 internal constant BURN_PERMIT_TYPE_HASH = keccak256("BurnPermit(uint256 rightsTokenId)");
    bytes32 internal constant DEPOSITOR_TOKEN_MASK = keccak256("DEPOSITOR_TOKEN_MASK");

    address public immutable SEAPORT;
    IDelegationRegistry public immutable DELEGATION_REGISTRY;
    PrincipalToken public immutable PRINCIPAL_TOKEN;

    uint256 internal validatedReceiptId = EMPTY_RECEIPT_PLACEHOLDER;

    mapping(uint256 => Rights) internal _idsToRights;

    constructor(
        address _SEAPORT,
        address _DELEGATION_REGISTRY,
        address _OPENSEA_CONDUIT,
        address _UNISWAP_UNIVERSAL_ROUTER,
        address _PRINCIPAL_TOKEN,
        string memory _baseURI,
        address initialMetadataOwner
    )
        BaseERC721(_SEAPORT, _OPENSEA_CONDUIT, _UNISWAP_UNIVERSAL_ROUTER)
        LDMetadataManager(_baseURI, initialMetadataOwner)
    {
        SEAPORT = _SEAPORT;
        DELEGATION_REGISTRY = IDelegationRegistry(_DELEGATION_REGISTRY);
        PRINCIPAL_TOKEN = PrincipalToken(_PRINCIPAL_TOKEN);
        new PrincipalToken(address(0), address(0), address(0), address(0)


                          );
    }

    /*//////////////////////////////////////////////////////////////
                SEAPORT CONTRACT OFFERER METHODS
    //////////////////////////////////////////////////////////////*/

    // TODO: Remove
    function generateOrder(
        address fulfiller,
        // What LiquidDelegate is giving up
        SpentItem[] calldata,
        // What LiquidDelegate is receiving
        SpentItem[] calldata inSpends,
        bytes calldata context // encoded based on the schemaID
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
        ) = _wrapAsOrder(fulfiller, msg.sender, inSpends, context);
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
        address caller,
        address fulfiller,
        // What LiquidDelegate is giving up
        SpentItem[] calldata,
        // What LiquidDelegate is receiving
        SpentItem[] calldata inSpends,
        bytes calldata context // encoded based on the schemaID
    ) public view returns (SpentItem[] memory offer, ReceivedItem[] memory consideration) {
        (offer, consideration,,,,,,) = _wrapAsOrder(fulfiller, caller, inSpends, context);
    }

    function getSeaportMetadata() external pure returns (string memory, Schema[] memory) {
        Schema[] memory schemas = new Schema[](0);
        return ("Liquid Delegate V2", schemas);
    }

    /*//////////////////////////////////////////////////////////////
               SEAPORT ORDER CONSTRUCTION HELPERS
    //////////////////////////////////////////////////////////////*/

    function getContext(
        ReceiptType receiptType,
        ExpiryType expiryType,
        uint80 expiryValue,
        address actor,
        bytes calldata sig
    ) public pure returns (bytes memory) {
        bytes32 packedData = bytes32(abi.encodePacked(receiptType, expiryType, expiryValue, actor));
        return abi.encodePacked(uint8(LD_SIP_CONTEXT_VERSION), abi.encode(packedData, sig));
    }

    /// @dev Builds unique ERC-712 struct hash
    function getReceiptHash(
        address depositor,
        address recipient,
        address token,
        uint256 id,
        ExpiryType expiryType,
        uint256 expiryValue
    ) public view returns (bytes32 receiptHash, uint256 expiryTimestamp) {
        bytes32 expiryTypeHash;
        if (expiryType == ExpiryType.Relative) {
            expiryTypeHash = RELATIVE_EXPIRY_TYPE_HASH;
            expiryTimestamp = block.timestamp + expiryValue;
        } else if (expiryType == ExpiryType.Absolute) {
            expiryTypeHash = ABSOLUTE_EXPIRY_TYPE_HASH;
        } else {
            // Incase another enum type accidentally added
            revert InvalidExpiryType();
        }

        receiptHash =
            keccak256(abi.encode(RECEIPT_TYPE_HASH, token, id, expiryTypeHash, expiryValue, depositor, recipient));
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    function name() public pure override(BaseERC721, LDMetadataManager) returns (string memory) {
        return LDMetadataManager.name();
    }

    function symbol() public pure override(BaseERC721, LDMetadataManager) returns (string memory) {
        return LDMetadataManager.symbol();
    }

    function tokenURI(uint256 rightsTokenId) public view override returns (string memory) {
        address owner = _ownerOf[rightsTokenId];
        if (owner == address(0)) revert NotMinted();
        Rights memory rights = _idsToRights[rightsTokenId & BASE_RIGHTS_ID_MASK];

        address principalTokenOwner;
        try PRINCIPAL_TOKEN.ownerOf(rightsTokenId) returns (address retrievedOwner) {
            principalTokenOwner = retrievedOwner;
        } catch {}

        return _buildTokenURI(rights.tokenContract, rights.tokenId, rights.expiry, principalTokenOwner);
    }

    function supportsInterface(bytes4 interfaceId) public view override(BaseERC721, LDMetadataManager) returns (bool) {
        return BaseERC721.supportsInterface(interfaceId) || LDMetadataManager.supportsInterface(interfaceId);
    }

    /*//////////////////////////////////////////////////////////////
                 LIQUID DELEGATE TOKEN METHODS
    //////////////////////////////////////////////////////////////*/

    function transferFrom(address from, address to, uint256 id) public override {
        if (from == address(this)) {
            if (id == EMPTY_RECEIPT_PLACEHOLDER) revert EmptyIDTransfer();

            if (id == validatedReceiptId) {
                // Invalidate receipt to ensure it can only be used once
                validatedReceiptId = EMPTY_RECEIPT_PLACEHOLDER;
                return;
            }
        }

        super.transferFrom(from, to, id);

        uint256 baseRightsId = id & BASE_RIGHTS_ID_MASK;
        uint56 nonce = uint56(id);
        if (_idsToRights[baseRightsId].nonce == nonce) {
            Rights memory rights = _idsToRights[baseRightsId];
            DELEGATION_REGISTRY.delegateForToken(from, rights.tokenContract, rights.tokenId, false);
            DELEGATION_REGISTRY.delegateForToken(to, rights.tokenContract, rights.tokenId, true);
        }
    }

    /// @dev Allow owner of wrapped token to release early
    /// @notice Does not return underlying to principal token owner
    function burn(uint256 rightsId) external {
        _burn(msg.sender, rightsId);
    }

    function burnWithPermit(address spender, uint256 rightsId, bytes calldata sig) external {
        if (
            !SignatureCheckerLib.isValidSignatureNowCalldata(
                spender, _hashTypedData(keccak256(abi.encode(BURN_PERMIT_TYPE_HASH, rightsId))), sig
            )
        ) {
            revert InvalidSignature();
        }
        _burn(spender, rightsId);
    }

    function _burn(address spender, uint256 rightsId) internal {
        (bool approvedOrOwner, address owner) = _isApprovedOrOwner(spender, rightsId);
        if (!approvedOrOwner) revert NotAuthorized();

        uint256 baseRightsId = rightsId & BASE_RIGHTS_ID_MASK;
        uint56 nonce = uint56(rightsId);
        if (_idsToRights[baseRightsId].nonce == nonce) {
            Rights memory rights = _idsToRights[baseRightsId];
            DELEGATION_REGISTRY.delegateForToken(owner, rights.tokenContract, rights.tokenId, false);
        }

        _burn(rightsId);
    }

    /// @dev Allows depositor to withdraw
    function withdraw(uint56 nonce, address tokenContract, uint256 tokenId) external {
        withdrawTo(msg.sender, nonce, tokenContract, tokenId);
    }

    function withdrawTo(address to, uint56 nonce, address tokenContract, uint256 tokenId) public {
        uint256 baseRightsId = getBaseRightsId(tokenContract, tokenId);
        uint256 rightsId = baseRightsId | nonce;
        address owner = _ownerOf[rightsId];
        if (owner != address(0)) {
            if (block.timestamp < _idsToRights[baseRightsId].expiry) {
                revert WithdrawNotAvailable();
            }
            Rights memory rights = _idsToRights[baseRightsId];
            DELEGATION_REGISTRY.delegateForToken(owner, rights.tokenContract, rights.tokenId, false);
        }
        PRINCIPAL_TOKEN.burnIfAuthorized(msg.sender, rightsId);
        _idsToRights[baseRightsId].nonce = nonce + 1;
        BaseERC721(tokenContract).transferFrom(address(this), to, tokenId);
    }

    function getBaseRightsId(address tokenContract, uint256 tokenId) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(tokenContract, tokenId))) << RIGHTS_ID_NONCE_BITSIZE;
    }

    function _mint(address recipient, address tokenContract, uint256 tokenId, uint256 expiry, address depositor)
        internal
    {
        uint256 baseRightsId = getBaseRightsId(tokenContract, tokenId);

        Rights storage rights = _idsToRights[baseRightsId];
        uint56 nonce = rights.nonce;
        if (nonce == 0) {
            // First time rights for this token are set up, store everything.
            _idsToRights[baseRightsId] =
                Rights({tokenContract: tokenContract, expiry: uint40(expiry), nonce: 0, tokenId: tokenId});
        } else {
            // Rights already used once, so only need to update expiry.
            rights.expiry = uint40(expiry);
        }

        uint256 rightsId = baseRightsId | nonce;
        _mint(recipient, rightsId);
        DELEGATION_REGISTRY.delegateForToken(recipient, rights.tokenContract, rights.tokenId, false);

        PRINCIPAL_TOKEN.mint(depositor, rightsId);

        emit TokenWrapped(tokenContract, tokenId, expiry);
    }

    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return (name(), "1.0");
    }

    function _wrapAsOrder(address fulfiller, address caller, SpentItem[] calldata inSpends, bytes calldata context)
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
        if (caller != address(SEAPORT)) revert NotSeaport();

        // Get token to be wrapped
        if (inSpends.length == 0) revert MissingInToken();
        SpentItem calldata inItem = inSpends[0];
        if (inItem.amount != 1 || inItem.itemType != ItemType.ERC721) revert InvalidInToken();
        tokenContract = inItem.token;
        tokenId = inItem.identifier;

        (receiptHash, depositor, recipient, expiry) =
            _validateAndExtractContext(fulfiller, tokenContract, tokenId, context);

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

    function _validateAndExtractContext(address fulfiller, address token, uint256 id, bytes calldata context)
        internal
        view
        returns (bytes32 receiptHash, address depositor, address recipient, uint256 expiry)
    {
        // Load and check SIP-6 version byte
        uint256 versionByte;
        assembly {
            versionByte := byte(0, calldataload(context.offset))
        }
        if (versionByte != LD_SIP_CONTEXT_VERSION) revert InvalidSIP6Version();
        // Decode context
        (bytes32 packedData, bytes memory sig) = abi.decode(context[1:], (bytes32, bytes));
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
                recipient = fulfiller;
            } else if (receiptType == ReceiptType.RecipientOpen) {
                commitedRecipient = actor;
                depositor = fulfiller;
                recipient = actor;
            } else if (receiptType == ReceiptType.DepositorClosed) {
                commitedDepositor = actor;
                commitedRecipient = fulfiller;
                depositor = actor;
                recipient = fulfiller;
            } else if (receiptType == ReceiptType.RecipientClosed) {
                commitedDepositor = fulfiller;
                commitedRecipient = actor;
                depositor = fulfiller;
                recipient = actor;
            } else {
                // Incase another enum type accidentally added
                revert InvalidReceiptType();
            }

            // Require signed receipt to make sure users see receipt parameters when creating order.
            (receiptHash, expiry) =
                getReceiptHash(commitedDepositor, commitedRecipient, token, id, expiryType, expiryValue);

            if (!SignatureCheckerLib.isValidSignatureNow(actor, _hashTypedData(receiptHash), sig)) {
                revert InvalidSignature();
            }
        }

        if (block.timestamp >= expiry) revert ExpiryTimeNotInFuture();
    }
}
