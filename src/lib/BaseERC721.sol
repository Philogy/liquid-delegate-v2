// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {ERC721} from "solmate/tokens/ERC721.sol";

import {IERC721Receiver} from "openzeppelin-contracts/token/ERC721/IERC721Receiver.sol";

/// @author philogy <https://github.com/philogy>
/// @author Adapted from solmate's [ERC721](https://github.com/transmissions11/solmate/blob/main/src/tokens/ERC721.sol)
abstract contract BaseERC721 is ERC721 {
    error NotAuthorized();
    error NotMinted();

    constructor(string memory name_, string memory symbol_) ERC721(name_, symbol_) {}

    function isApprovedOrOwner(address spender, uint256 id) public view returns (bool) {
        (bool approvedOrOwner, address owner) = _isApprovedOrOwner(spender, id);
        if (owner == address(0)) revert NotMinted();
        return approvedOrOwner;
    }

    function _isApprovedOrOwner(address spender, uint256 id)
        internal
        view
        returns (bool approvedOrOwner, address owner)
    {
        owner = _ownerOf[id];
        approvedOrOwner = spender == owner || isApprovedForAll[owner][spender] || getApproved[id] == spender;
    }
}
