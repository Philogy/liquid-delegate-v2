// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {ContractOffererInterface, Schema} from "seaport/interfaces/ContractOffererInterface.sol";
import {ERC2981} from "openzeppelin-contracts/token/common/ERC2981.sol";
import {Owned} from "solmate/auth/Owned.sol";

import {LibString} from "solady/utils/LibString.sol";
import {Base64} from "solady/utils/Base64.sol";

/// @author philogy <https://github.com/philogy>
abstract contract LDMetadataManager is ERC2981, ContractOffererInterface, Owned {
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

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function setBaseURI(string memory _baseURI) external onlyOwner {
        baseURI = _baseURI;
    }

    /// @dev Returns contract-level metadata URI for OpenSea (reference)[https://docs.opensea.io/docs/contract-level-metadata]
    function contractURI() public view returns (string memory) {
        return string.concat(baseURI, "contract");
    }

    function _buildTokenURI(address tokenContract, uint256 tokenId, uint40 expiry, address principalOwner)
        internal
        view
        returns (string memory)
    {
        string memory tokenAsStr = tokenId.toString();
        string memory tokenName;
        string memory attributes;
        string memory imageUrl = string.concat(baseURI, "rights/", tokenAsStr);

        if (principalOwner == address(0)) {
            tokenName = string.concat(name(), "(Expired) #", tokenAsStr);
            attributes = string.concat(
                '[{"trait_type":"Collection Address","value":"',
                tokenContract.toHexStringChecksumed(),
                '"},{"trait_type":"Token ID","value":"',
                tokenAsStr,
                '"},{"trait_type":"Principal Owner Address","value":"No Owner (Underlying Token Withdrawn)"},{"trait_type":"Delegate Status","value":"Expired"}]'
            );
        } else if (expiry < block.timestamp) {
            tokenName = string.concat(name(), "(Expired) #", tokenAsStr);
            attributes = string.concat(
                '[{"trait_type":"Collection Address","value":"',
                tokenContract.toHexStringChecksumed(),
                '"},{"trait_type":"Token ID","value":"',
                tokenAsStr,
                '"},{"trait_type":"Expiration","display_type":"date","value":',
                uint256(expiry).toString(),
                '},{"trait_type":"Principal Owner Address","value":"',
                principalOwner.toHexStringChecksumed(),
                '"},{"trait_type":"Delegate Status","value":"Expired"}]'
            );
        } else {
            tokenName = string.concat(name(), " #", tokenAsStr);
            attributes = string.concat(
                '[{"trait_type":"Collection Address","value":"',
                tokenContract.toHexStringChecksumed(),
                '"},{"trait_type":"Token ID","value":"',
                tokenAsStr,
                '"},{"trait_type":"Expiration","display_type":"date","value":',
                uint256(expiry).toString(),
                '},{"trait_type":"Principal Owner Address","value":"',
                principalOwner.toHexStringChecksumed(),
                '"},{"trait_type":"Delegate Status","value":"Active"}]'
            );
        }

        string memory metadataString = string.concat(
            '{"name":"',
            tokenName,
            '","description":"LiquidDelegate lets you escrow your token for a chosen timeperiod and receive a liquid NFT representing the associated delegation rights.",',
            attributes,
            ',"image":"',
            imageUrl,
            '"}'
        );

        return string.concat("data:application/json;base64,", Base64.encode(bytes(metadataString)));
    }
}
