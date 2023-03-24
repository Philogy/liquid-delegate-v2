// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {BaseERC721} from "./lib/BaseERC721.sol";
import {EIP712} from "solady/utils/EIP712.sol";
import {Multicallable} from "solady/utils/Multicallable.sol";
import {LDMetadataManager} from "./LDMetadataManager.sol";
import {ILiquidDelegateV2, ExpiryType, Rights} from "./interfaces/ILiquidDelegateV2.sol";
import {IERC165} from "openzeppelin-contracts/utils/introspection/IERC165.sol";

import {SignatureCheckerLib} from "solady/utils/SignatureCheckerLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

import {IERC721} from "openzeppelin-contracts/token/ERC721/IERC721.sol";
import {IDelegationRegistry} from "./interfaces/IDelegationRegistry.sol";
import {PrincipalToken} from "./PrincipalToken.sol";

/// @author philogy <https://github.com/philogy>
/// @dev V2 of Liquid Delegate
contract LiquidDelegateV2 is ILiquidDelegateV2, BaseERC721, EIP712, Multicallable, LDMetadataManager {
    using SafeCastLib for uint256;

    // TODO: Better names for users
    bytes32 internal constant RELATIVE_EXPIRY_TYPE_HASH = keccak256("Relative");
    bytes32 internal constant ABSOLUTE_EXPIRY_TYPE_HASH = keccak256("Absolute");

    uint256 internal constant BASE_RIGHTS_ID_MASK = 0xffffffffffffffffffffffffffffffffffffffffffffffffff00000000000000;
    uint256 internal constant RIGHTS_ID_NONCE_BITSIZE = 56;

    bytes32 internal constant BURN_PERMIT_TYPE_HASH = keccak256("BurnPermit(uint256 rightsTokenId)");

    address public immutable override DELEGATION_REGISTRY;
    address public immutable override PRINCIPAL_TOKEN;

    mapping(uint256 => Rights) internal $idsToRights;

    constructor(
        address _DELEGATION_REGISTRY,
        address _SEAPORT,
        address _OPENSEA_CONDUIT,
        address _UNISWAP_UNIVERSAL_ROUTER,
        address _PRINCIPAL_TOKEN,
        string memory _baseURI,
        address initialMetadataOwner
    )
        BaseERC721(_SEAPORT, _OPENSEA_CONDUIT, _UNISWAP_UNIVERSAL_ROUTER)
        LDMetadataManager(_baseURI, initialMetadataOwner)
    {
        DELEGATION_REGISTRY = _DELEGATION_REGISTRY;
        PRINCIPAL_TOKEN = _PRINCIPAL_TOKEN;
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

    function version() public pure returns (string memory) {
        return "1";
    }

    function tokenURI(uint256 rightsTokenId) public view override returns (string memory) {
        if ($ownerOf[rightsTokenId] == address(0)) revert NotMinted();
        Rights memory rights = $idsToRights[rightsTokenId & BASE_RIGHTS_ID_MASK];

        address principalTokenOwner;
        try PrincipalToken(PRINCIPAL_TOKEN).ownerOf(rightsTokenId) returns (address retrievedOwner) {
            principalTokenOwner = retrievedOwner;
        } catch {}

        return _buildTokenURI(rights.tokenContract, rights.tokenId, rights.expiry, principalTokenOwner);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(BaseERC721, LDMetadataManager, IERC165)
        returns (bool)
    {
        return BaseERC721.supportsInterface(interfaceId) || LDMetadataManager.supportsInterface(interfaceId);
    }

    function getRights(uint256 rightsId) external view returns (uint256 baseRightsId, Rights memory rights) {
        baseRightsId = rightsId & BASE_RIGHTS_ID_MASK;
        rights = $idsToRights[baseRightsId];
        if (rights.tokenContract == address(0)) revert NoRights();
    }

    function transferFrom(address from, address to, uint256 id) public override(BaseERC721, IERC721) {
        super.transferFrom(from, to, id);

        uint256 baseRightsId = id & BASE_RIGHTS_ID_MASK;
        uint56 nonce = uint56(id);
        if ($idsToRights[baseRightsId].nonce == nonce) {
            Rights memory rights = $idsToRights[baseRightsId];
            IDelegationRegistry(DELEGATION_REGISTRY).delegateForToken(from, rights.tokenContract, rights.tokenId, false);
            IDelegationRegistry(DELEGATION_REGISTRY).delegateForToken(to, rights.tokenContract, rights.tokenId, true);
        }
    }

    /*//////////////////////////////////////////////////////////////
                 LIQUID DELEGATE TOKEN METHODS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Creates LD Token pair after token has been deposited. **Do not** attempt to use as normal wallet.
     */
    function mint(
        address delegateRecipient,
        address principalRecipient,
        address tokenContract,
        uint256 tokenId,
        ExpiryType expiryType,
        uint256 expiryValue
    ) external returns (uint256) {
        if (IERC721(tokenContract).ownerOf(tokenId) != address(this)) revert UnderlyingMissing();
        uint40 expiry = getExpiry(expiryType, expiryValue);
        return _mint(delegateRecipient, principalRecipient, tokenContract, tokenId, expiry);
    }

    function create(
        address delegateRecipient,
        address principalRecipient,
        address tokenContract,
        uint256 tokenId,
        ExpiryType expiryType,
        uint256 expiryValue
    ) external returns (uint256) {
        IERC721(tokenContract).transferFrom(msg.sender, address(this), tokenId);
        uint40 expiry = getExpiry(expiryType, expiryValue);
        return _mint(delegateRecipient, principalRecipient, tokenContract, tokenId, expiry);
    }

    function extend(uint256 rightsId, ExpiryType expiryType, uint256 expiryValue) external {
        if (!PrincipalToken(PRINCIPAL_TOKEN).isApprovedOrOwner(msg.sender, rightsId)) revert NotAuthorized();
        uint40 newExpiry = getExpiry(expiryType, expiryValue);
        uint256 baseRightsId = rightsId & BASE_RIGHTS_ID_MASK;
        uint40 currentExpiry = $idsToRights[baseRightsId].expiry;
        if (newExpiry <= currentExpiry) revert NotExtending();
        $idsToRights[baseRightsId].expiry = newExpiry;
        emit RightsExtended(baseRightsId, uint56(rightsId), currentExpiry, newExpiry);
    }

    function _mint(
        address delegateRecipient,
        address principalRecipient,
        address tokenContract,
        uint256 tokenId,
        uint40 expiry
    ) internal returns (uint256 rightsId) {
        uint256 baseRightsId = getBaseRightsId(tokenContract, tokenId);
        Rights storage rights = $idsToRights[baseRightsId];
        uint56 nonce = rights.nonce;
        rightsId = baseRightsId | nonce;

        if (nonce == 0) {
            // First time rights for this token are set up, store everything.
            $idsToRights[baseRightsId] =
                Rights({tokenContract: tokenContract, expiry: uint40(expiry), nonce: 0, tokenId: tokenId});
        } else {
            // Rights already used once, so only need to update expiry.
            rights.expiry = uint40(expiry);
        }

        _mint(delegateRecipient, rightsId);
        IDelegationRegistry(DELEGATION_REGISTRY).delegateForToken(
            delegateRecipient, rights.tokenContract, rights.tokenId, true
        );

        PrincipalToken(PRINCIPAL_TOKEN).mint(principalRecipient, rightsId);

        emit RightsCreated(baseRightsId, nonce, expiry);
    }

    function getExpiry(ExpiryType expiryType, uint256 expiryValue) public view returns (uint40 expiry) {
        if (expiryType == ExpiryType.Relative) {
            expiry = (block.timestamp + expiryValue).toUint40();
        } else if (expiryType == ExpiryType.Absolute) {
            expiry = expiryValue.toUint40();
        } else {
            revert InvalidExpiryType();
        }
        if (expiry <= block.timestamp) revert ExpiryTimeNotInFuture();
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
        if ($idsToRights[baseRightsId].nonce == nonce) {
            Rights memory rights = $idsToRights[baseRightsId];
            IDelegationRegistry(DELEGATION_REGISTRY).delegateForToken(
                owner, rights.tokenContract, rights.tokenId, false
            );
        }

        _burn(rightsId);
        emit RightsBurned(baseRightsId, nonce);
    }

    /// @dev Allows depositor to withdraw
    function withdraw(uint56 nonce, address tokenContract, uint256 tokenId) external {
        withdrawTo(msg.sender, nonce, tokenContract, tokenId);
    }

    function withdrawTo(address to, uint56 nonce, address tokenContract, uint256 tokenId) public {
        uint256 baseRightsId = getBaseRightsId(tokenContract, tokenId);
        uint256 rightsId = baseRightsId | nonce;
        address owner = $ownerOf[rightsId];
        if (owner != address(0)) {
            if (block.timestamp < $idsToRights[baseRightsId].expiry) {
                revert WithdrawNotAvailable();
            }
            Rights memory rights = $idsToRights[baseRightsId];
            IDelegationRegistry(DELEGATION_REGISTRY).delegateForToken(
                owner, rights.tokenContract, rights.tokenId, false
            );
        }
        PrincipalToken(PRINCIPAL_TOKEN).burnIfAuthorized(msg.sender, rightsId);
        $idsToRights[baseRightsId].nonce = nonce + 1;
        emit UnderlyingWithdrawn(baseRightsId, nonce, to);
        IERC721(tokenContract).transferFrom(address(this), to, tokenId);
    }

    function getBaseRightsId(address tokenContract, uint256 tokenId) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(tokenContract, tokenId))) << RIGHTS_ID_NONCE_BITSIZE;
    }

    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return (name(), version());
    }
}
