// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Test} from "forge-std/Test.sol";
import {Seaport} from "seaport/Seaport.sol";
import {ConduitController} from "seaport/conduit/ConduitController.sol";
import {Conduit} from "seaport/conduit/Conduit.sol";

/// @author philogy <https://github.com/philogy>
contract BaseSeaportTest is Test {
    ConduitController conduitController;
    Conduit conduit;
    Seaport seaport;
    bytes32 conduitKey;

    address conduitOwner = makeAddr("CONDUIT_OWNER");

    constructor() {
        conduitController = new ConduitController();
        seaport = new Seaport(address(conduitController));

        vm.startPrank(conduitOwner);
        conduitKey = bytes32(abi.encodePacked(conduitOwner, uint96(0)));
        conduit = Conduit(conduitController.createConduit(conduitKey, conduitOwner));
        conduitController.updateChannel(address(conduit), address(seaport), true);
        vm.stopPrank();
    }
}
