// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {IERC721} from "openzeppelin-contracts/token/ERC721/IERC721.sol";

enum ExpiryType {
    Relative,
    Absolute
}

struct Rights {
    address tokenContract;
    uint40 expiry;
    uint56 nonce;
    uint256 tokenId;
}

/// @author philogy <https://github.com/philogy>
interface ILiquidDelegateV2 is IERC721 {
    /*//////////////////////////////////////////////////////////////
                             ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidSignature();
    error InvalidExpiryType();
    error ExpiryTimeNotInFuture();
    error WithdrawNotAvailable();
    error UnderlyingMissing();
    error NotExtending();
    error NoRights();
    error NotContract();

    /*//////////////////////////////////////////////////////////////
                             EVENTS
    //////////////////////////////////////////////////////////////*/

    event RightsCreated(uint256 indexed baseRightsId, uint56 indexed nonce, uint40 expiry);
    event RightsExtended(uint256 indexed baseRightsId, uint56 indexed nonce, uint40 previousExpiry, uint40 newExpiry);
    event RightsBurned(uint256 indexed baseRightsId, uint56 indexed nonce);
    event UnderlyingWithdrawn(uint256 indexed baseRightsId, uint56 indexed nonce, address to);

    /*//////////////////////////////////////////////////////////////
                      VIEW & INTROSPECTION
    //////////////////////////////////////////////////////////////*/

    function DELEGATION_REGISTRY() external view returns (address);
    function PRINCIPAL_TOKEN() external view returns (address);
    function getRights(uint256 rightsId) external view returns (uint256 baseRightsId, Rights memory rights);
    function getExpiry(ExpiryType expiryType, uint256 expiryValue) external view returns (uint40);

    /*//////////////////////////////////////////////////////////////
                         CREATE METHODS
    //////////////////////////////////////////////////////////////*/

    function mint(
        address ldRecipient,
        address principalRecipient,
        address tokenContract,
        uint256 tokenId,
        ExpiryType expiryType,
        uint256 expiryValue
    ) external returns (uint256);

    function create(
        address ldRecipient,
        address principalRecipient,
        address tokenContract,
        uint256 tokenId,
        ExpiryType expiryType,
        uint256 expiryValue
    ) external returns (uint256);

    function extend(uint256 rightsId, ExpiryType expiryType, uint256 expiryValue) external;

    /*//////////////////////////////////////////////////////////////
                         REDEEM METHODS
    //////////////////////////////////////////////////////////////*/

    function burn(uint256 rightsId) external;
    function burnWithPermit(address from, uint256 rightsId, bytes calldata sig) external;

    function withdraw(uint56 nonce, address tokenContract, uint256 tokenId) external;
    function withdrawTo(address to, uint56 nonce, address tokenContract, uint256 tokenId) external;
}
