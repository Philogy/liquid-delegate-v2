// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {OrderParameters} from "seaport/lib/ConsiderationStructs.sol";
import {SeaportHashLib} from "./SeaportHashLib.sol";

struct User {
    address addr;
    uint256 key;
}

/// @author philogy <https://github.com/philogy>
abstract contract SeaportHelpers is Test {
    using SeaportHashLib for OrderParameters;
    using SeaportHashLib for bytes32;

    function makeUser(string memory _name) internal returns (User memory) {
        (address addr, uint256 key) = makeAddrAndKey(_name);
        return User(addr, key);
    }

    function signERC712(User memory _user, bytes32 _domainSeparator, bytes32 _structHash)
        internal
        pure
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_user.key, _domainSeparator.erc712DigestOf(_structHash));
        return abi.encodePacked(r, s, v);
    }

    function signOrder(User memory _user, bytes32 _domainSeparator, OrderParameters memory _orderParams, uint256 _nonce)
        internal
        pure
        returns (bytes memory)
    {
        return signERC712(_user, _domainSeparator, _orderParams.hash(_nonce));
    }
}
