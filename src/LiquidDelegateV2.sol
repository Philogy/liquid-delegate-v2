// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {BaseERC721} from "./lib/BaseERC721.sol";
import {EIP712} from "solady/utils/EIP712.sol";
import {Multicallable} from "solady/utils/Multicallable.sol";
import {LDMetadataManager} from "./LDMetadataManager.sol";
import {ILiquidDelegateV2Base, ExpiryType, Rights} from "./interfaces/ILiquidDelegateV2.sol";

import {SignatureCheckerLib} from "solady/utils/SignatureCheckerLib.sol";
import {SafeCastLib} from "solady/utils/SafeCastLib.sol";

import {IERC721} from "openzeppelin-contracts/token/ERC721/IERC721.sol";
import {ERC721} from "solmate/tokens/ERC721.sol";
import {IDelegationRegistry} from "./interfaces/IDelegationRegistry.sol";
import {PrincipalToken} from "./PrincipalToken.sol";
import {INFTFlashBorrower} from "./interfaces/INFTFlashBorrower.sol";

/// @author philogy <https://github.com/philogy>
/// @dev V2 of Liquid Delegate
contract LiquidDelegateV2 is ILiquidDelegateV2Base, BaseERC721, EIP712, Multicallable, LDMetadataManager {
    using SafeCastLib for uint256;

    bytes32 public constant FLASHLOAN_CALLBACK_MAGIC = bytes32(uint256(keccak256("LiquidDelegate.v2.onFlashLoan")) - 1);

    uint256 internal constant BASE_RIGHTS_ID_MASK = 0xffffffffffffffffffffffffffffffffffffffffffffffffff00000000000000;
    uint256 internal constant RIGHTS_ID_NONCE_BITSIZE = 56;

    bytes32 internal constant BURN_PERMIT_TYPE_HASH = keccak256("BurnPermit(uint256 rightsTokenId)");

    address public immutable override DELEGATION_REGISTRY;
    address public immutable override PRINCIPAL_TOKEN;

    mapping(uint256 => Rights) internal _idsToRights;

    constructor(
        address _DELEGATION_REGISTRY,
        address _PRINCIPAL_TOKEN,
        string memory _baseURI,
        address initialMetadataOwner
    ) BaseERC721(_name(), _symbol()) LDMetadataManager(_baseURI, initialMetadataOwner) {
        DELEGATION_REGISTRY = _DELEGATION_REGISTRY;
        PRINCIPAL_TOKEN = _PRINCIPAL_TOKEN;
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparator();
    }

    function version() public pure returns (string memory) {
        return "1";
    }

    function baseURI() public view override(ILiquidDelegateV2Base, LDMetadataManager) returns (string memory) {
        return LDMetadataManager.baseURI();
    }

    function tokenURI(uint256 rightsTokenId) public view override returns (string memory) {
        if (_ownerOf[rightsTokenId] == address(0)) revert NotMinted();
        Rights memory rights = _idsToRights[rightsTokenId & BASE_RIGHTS_ID_MASK];

        address principalTokenOwner;
        try PrincipalToken(PRINCIPAL_TOKEN).ownerOf(rightsTokenId) returns (address retrievedOwner) {
            principalTokenOwner = retrievedOwner;
        } catch {}

        return _buildTokenURI(rights.tokenContract, rights.tokenId, rights.expiry, principalTokenOwner);
    }

    function supportsInterface(bytes4 interfaceId) public view override(LDMetadataManager, ERC721) returns (bool) {
        return ERC721.supportsInterface(interfaceId) || LDMetadataManager.supportsInterface(interfaceId);
    }

    function getRights(address tokenContract, uint256 tokenId)
        public
        view
        returns (uint256 baseRightsId, uint256 activeRightsId, Rights memory rights)
    {
        baseRightsId = getBaseRightsId(tokenContract, tokenId);
        rights = _idsToRights[baseRightsId];
        activeRightsId = baseRightsId | rights.nonce;
        if (rights.tokenContract == address(0)) revert NoRights();
    }

    function getRights(uint256 rightsId)
        public
        view
        returns (uint256 baseRightsId, uint256 activeRightsId, Rights memory rights)
    {
        baseRightsId = rightsId & BASE_RIGHTS_ID_MASK;
        rights = _idsToRights[baseRightsId];
        activeRightsId = baseRightsId | rights.nonce;
        if (rights.tokenContract == address(0)) revert NoRights();
    }

    function transferFrom(address from, address to, uint256 id) public override {
        super.transferFrom(from, to, id);

        uint256 baseRightsId = id & BASE_RIGHTS_ID_MASK;
        uint56 nonce = uint56(id);
        if (_idsToRights[baseRightsId].nonce == nonce) {
            Rights memory rights = _idsToRights[baseRightsId];
            IDelegationRegistry(DELEGATION_REGISTRY).delegateForToken(from, rights.tokenContract, rights.tokenId, false);
            IDelegationRegistry(DELEGATION_REGISTRY).delegateForToken(to, rights.tokenContract, rights.tokenId, true);
        }
    }

    function flashLoan(address receiver, uint256 rightsId, address tokenContract, uint256 tokenId, bytes calldata data)
        external
    {
        if (!PrincipalToken(PRINCIPAL_TOKEN).isApprovedOrOwner(msg.sender, rightsId)) revert NotAuthorized();
        if (getBaseRightsId(tokenContract, tokenId) != rightsId & BASE_RIGHTS_ID_MASK) revert InvalidFlashloan();
        IERC721(tokenContract).transferFrom(address(this), receiver, tokenId);

        if (
            INFTFlashBorrower(receiver).onFlashLoan(msg.sender, tokenContract, tokenId, data)
                != FLASHLOAN_CALLBACK_MAGIC
        ) revert InvalidFlashloan();

        // Safer and cheaper to expect the token to have been returned rather than pulling it with
        // `transferFrom`.
        if (IERC721(tokenContract).ownerOf(tokenId) != address(this)) revert InvalidFlashloan();
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
        uint40 currentExpiry = _idsToRights[baseRightsId].expiry;
        if (newExpiry <= currentExpiry) revert NotExtending();
        _idsToRights[baseRightsId].expiry = newExpiry;
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
        Rights storage rights = _idsToRights[baseRightsId];
        uint56 nonce = rights.nonce;
        rightsId = baseRightsId | nonce;

        if (nonce == 0) {
            // First time rights for this token are set up, store everything.
            _idsToRights[baseRightsId] =
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
        _burnAuth(msg.sender, rightsId);
    }

    function burnWithPermit(address spender, uint256 rightsId, bytes calldata sig) external {
        if (
            !SignatureCheckerLib.isValidSignatureNowCalldata(
                spender, _hashTypedData(keccak256(abi.encode(BURN_PERMIT_TYPE_HASH, rightsId))), sig
            )
        ) {
            revert InvalidSignature();
        }
        _burnAuth(spender, rightsId);
    }

    /// @dev Allows depositor to withdraw
    function withdraw(uint56 nonce, address tokenContract, uint256 tokenId) external {
        withdrawTo(msg.sender, nonce, tokenContract, tokenId);
    }

    function withdrawTo(address to, uint56 nonce, address tokenContract, uint256 tokenId) public {
        uint256 baseRightsId = getBaseRightsId(tokenContract, tokenId);
        uint256 rightsId = baseRightsId | nonce;
        PrincipalToken(PRINCIPAL_TOKEN).burnIfAuthorized(msg.sender, rightsId);

        // Check whether the delegate token still exists.
        address owner = _ownerOf[rightsId];
        if (owner != address(0)) {
            // If it still exists the only valid way to withdraw is the delegation having expired.
            if (block.timestamp < _idsToRights[baseRightsId].expiry) {
                revert WithdrawNotAvailable();
            }
            _burn(owner, rightsId);
        }
        _idsToRights[baseRightsId].nonce = nonce + 1;
        emit UnderlyingWithdrawn(baseRightsId, nonce, to);
        IERC721(tokenContract).transferFrom(address(this), to, tokenId);
    }

    function getBaseRightsId(address tokenContract, uint256 tokenId) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(tokenContract, tokenId))) & BASE_RIGHTS_ID_MASK;
    }

    function _burnAuth(address spender, uint256 rightsId) internal {
        (bool approvedOrOwner, address owner) = _isApprovedOrOwner(spender, rightsId);
        if (!approvedOrOwner) revert NotAuthorized();
        _burn(owner, rightsId);
    }

    function _burn(address owner, uint256 rightsId) internal {
        uint256 baseRightsId = rightsId & BASE_RIGHTS_ID_MASK;
        uint56 nonce = uint56(rightsId);

        Rights memory rights = _idsToRights[baseRightsId];
        IDelegationRegistry(DELEGATION_REGISTRY).delegateForToken(owner, rights.tokenContract, rights.tokenId, false);

        _burn(rightsId);
        emit RightsBurned(baseRightsId, nonce);
    }

    function _domainNameAndVersion() internal pure override returns (string memory, string memory) {
        return (_name(), version());
    }
}
