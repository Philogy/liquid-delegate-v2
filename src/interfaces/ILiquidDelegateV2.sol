// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {IERC721} from "openzeppelin-contracts/token/ERC721/IERC721.sol";

enum ExpiryType {
    Relative,
    Absolute
}

/// @author philogy <https://github.com/philogy>
interface ILiquidDelegateV2 is IERC721 {
    function DELEGATION_REGISTRY() external view returns (address);
    function PRINCIPAL_TOKEN() external view returns (address);

    function getExpiry(ExpiryType expiryType, uint256 expiryValue) external view returns (uint40);

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

    function burn(uint256 rightsId) external;
    function burnWithPermit(address from, uint256 rightsId, bytes calldata sig) external;

    function withdraw(uint56 nonce, address tokenContract, uint256 tokenId) external;
    function withdrawTo(address to, uint56 nonce, address tokenContract, uint256 tokenId) external;
}
