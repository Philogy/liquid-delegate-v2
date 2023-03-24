// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {ContractOffererInterface} from "seaport/interfaces/ContractOffererInterface.sol";

/// @author philogy <https://github.com/philogy>
interface IWrapOfferer is ContractOffererInterface {
    function transferFrom(address from, address to, uint256 receiptId) external;
}
