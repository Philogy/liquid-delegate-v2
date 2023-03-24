// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {ERC2981} from "openzeppelin-contracts/token/common/ERC2981.sol";
import {IERC165} from "openzeppelin-contracts/utils/introspection/IERC165.sol";
import {Owned} from "solmate/auth/Owned.sol";
import {ILiquidDelegateV2} from "./interfaces/ILiquidDelegateV2.sol";

import {LibString} from "solady/utils/LibString.sol";
import {Base64} from "solady/utils/Base64.sol";

/// @author philogy <https://github.com/philogy>
abstract contract LDMetadataManager is ERC2981, Owned, ILiquidDelegateV2 {
    using LibString for address;
    using LibString for uint256;

    string public baseURI;

    constructor(string memory _baseURI, address initialOwner) Owned(initialOwner) {
        baseURI = _baseURI;
    }

    function name() public pure virtual returns (string memory) {
        return "Liquid Delegate V2";
    }

    function symbol() public pure virtual returns (string memory) {
        return "RIGHTSV2";
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC2981, IERC165) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function setBaseURI(string memory _baseURI) external onlyOwner {
        baseURI = _baseURI;
    }

    /// @dev Returns contract-level metadata URI for OpenSea (reference)[https://docs.opensea.io/docs/contract-level-metadata]
    function contractURI() public view returns (string memory) {
        return string.concat(baseURI, "contract");
    }

    function _buildTokenURI(address tokenContract, uint256 id, uint40 expiry, address principalOwner)
        internal
        view
        returns (string memory)
    {
        string memory idstr = id.toString();

        string memory pownerstr = principalOwner == address(0) ? "N/A" : principalOwner.toHexStringChecksumed();
        string memory status = principalOwner == address(0) || expiry <= block.timestamp ? "Expired" : "Active";

        string memory metadataString = string.concat(
            '{"name":"',
            name(),
            " #",
            idstr,
            '","description":"LiquidDelegate lets you escrow your token for a chosen timeperiod and receive a liquid NFT representing the associated delegation rights. This collection represents the tokenized delegation rights.","attributes":[{"trait_type":"Collection Address","value":"',
            tokenContract.toHexStringChecksumed(),
            '"},{"trait_type":"Token ID","value":"',
            idstr,
            '"},{"trait_type":"Expires At","display_type":"date","value":',
            uint256(expiry).toString(),
            '},{"trait_type":"Principal Owner Address","value":"',
            pownerstr,
            '"},{"trait_type":"Delegate Status","value":"',
            status,
            '"}]',
            ',"image":"',
            baseURI,
            "rights/",
            idstr,
            '"}'
        );

        return string.concat("data:application/json;base64,", Base64.encode(bytes(metadataString)));
    }

    /// @dev See {ERC2981-_setDefaultRoyalty}.
    function setDefaultRoyalty(address receiver, uint96 feeNumerator) external onlyOwner {
        _setDefaultRoyalty(receiver, feeNumerator);
    }

    /// @dev See {ERC2981-_deleteDefaultRoyalty}.
    function deleteDefaultRoyalty() external onlyOwner {
        _deleteDefaultRoyalty();
    }
}
