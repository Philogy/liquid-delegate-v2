// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {BaseERC721} from "./lib/BaseERC721.sol";

/// @author philogy <https://github.com/philogy>
contract PrincipalToken is BaseERC721 {
    address public immutable LD_CONTROLLER;

    error NotLD();

    modifier onlyLD() {
        if (msg.sender != LD_CONTROLLER) revert NotLD();
        _;
    }

    constructor(address _LD_CONTROLLER, address defaultApproved1, address defaultApproved2, address defaultApproved3)
        BaseERC721(defaultApproved1, defaultApproved2, defaultApproved3)
    {
        LD_CONTROLLER = _LD_CONTROLLER;
    }

    function mint(address to, uint256 id) external onlyLD {
        _mint(to, id);
    }

    function burnIfAuthorized(address burner, uint256 id) external onlyLD {
        // Owner != 0 check also done by `_burn`.
        (bool approvedOrOwner,) = _isApprovedOrOwner(burner, id);
        if (!approvedOrOwner) revert NotAuthorized();
        _burn(id);
    }

    /*//////////////////////////////////////////////////////////////
                        METADATA METHODS
    //////////////////////////////////////////////////////////////*/

    function name() public pure override returns (string memory) {
        return "Prinicipal Tokens (LiquidDelegate V2)";
    }

    function symbol() public pure override returns (string memory) {
        return "LDP";
    }

    function tokenURI(uint256) public view override returns (string memory) {
        balanceOf(address(0));
        return "";
    }
}
