// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

/// @author philogy <https://github.com/philogy>
library Bool256Lib {
    function get(uint256 bitmap, uint256 index) internal pure returns (bool r) {
        assembly {
            r := and(shr(index, bitmap), 1)
        }
    }

    function set(uint256 bitmap, uint256 index, bool newValue) internal pure returns (uint256 newBitmap) {
        assembly {
            let currentValue := and(shr(index, bitmap), 1)
            newBitmap := xor(bitmap, shl(index, xor(currentValue, newValue)))
        }
    }
}
