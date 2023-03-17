// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {ERC721} from "solmate/tokens/ERC721.sol";

/// @author philogy <https://github.com/philogy>
contract MockERC721 is ERC721("Mock ERC721", "MOCK") {
    function mint(address _recipient, uint256 _tokenId) external {
        _mint(_recipient, _tokenId);
    }

    function tokenURI(uint256) public pure override returns (string memory) {
        return "";
    }
}
