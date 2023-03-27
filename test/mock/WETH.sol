// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {CommonBase} from "forge-std/Base.sol";

/// @author philogy <https://github.com/philogy>
contract WETH is ERC20("WETH", "WETH", 18), CommonBase {
    function mint(address to, uint256 wad) external {
        vm.deal(address(this), address(this).balance + wad);
        _mint(to, wad);
    }

    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 wad) external {
        _burn(msg.sender, wad);
        (bool success,) = msg.sender.call{value: wad}("");
        require(success);
    }
}
