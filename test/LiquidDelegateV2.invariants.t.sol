// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {InvariantTest} from "forge-std/InvariantTest.sol";

import {LibRLP} from "solady/utils/LibRLP.sol";
import {LiquidDelegateHandler} from "./handlers/LiquidDelegateHandler.sol";
import {LiquidDelegateV2, Rights} from "src/LiquidDelegateV2.sol";
import {PrincipalToken} from "src/PrincipalToken.sol";
import {DelegationRegistry} from "src/DelegationRegistry.sol";

import {IERC721} from "openzeppelin-contracts/token/ERC721/IERC721.sol";

/// @author philogy <https://github.com/philogy>
contract LiquidDelegateV2Invariants is Test, InvariantTest {
    DelegationRegistry internal registry;
    PrincipalToken internal principal;
    LiquidDelegateV2 internal ld;

    address internal coreDeployer = makeAddr("coreDeployer");
    address internal ldOwner = makeAddr("ldOwner");

    LiquidDelegateHandler internal handler;

    bytes4[] internal selectors;

    function setUp() public {
        // Deploy contracts.
        registry = new DelegationRegistry();

        vm.startPrank(coreDeployer);
        ld = new LiquidDelegateV2(
            address(registry),
            LibRLP.computeAddress(coreDeployer, vm.getNonce(coreDeployer) + 1),
            "",
            ldOwner
        );
        principal = new PrincipalToken(
            address(ld)
        );
        vm.stopPrank();

        handler = new LiquidDelegateHandler(address(ld));

        // Add target selectors.
        selectors.push(handler.createLdToken.selector);
        selectors.push(handler.transferLdToken.selector);
        selectors.push(handler.burnLdToken.selector);
        selectors.push(handler.withdrawExpired.selector);
        selectors.push(handler.withdrawBurned.selector);
        selectors.push(handler.extend.selector);

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));

        targetContract(address(handler));
    }

    function invariant_depositedTokensInLD() public {
        handler.forEachDepositedToken(this.tokenInLD);
    }

    function tokenInLD(address tokenContract, uint256 tokenId) external {
        assertEq(IERC721(tokenContract).ownerOf(tokenId), address(ld));
    }

    function invariant_oneTokenDelegatePerToken() public {
        handler.forEachDepositedToken(this.singleDelegate);
    }

    function singleDelegate(address tokenContract, uint256 tokenId) external {
        assertEq(registry.getDelegatesForAll(address(ld)).length, 0);
        assertEq(registry.getDelegatesForContract(address(ld), tokenContract).length, 0);
        assertEq(registry.getDelegatesForToken(address(ld), tokenContract, tokenId).length, 1);
    }

    function invariant_delegateOwnerDelegated() public {
        handler.forEachDepositedToken(this.delegateOwnerDelegated);
    }

    function delegateOwnerDelegated(address tokenContract, uint256 tokenId) external {
        (, uint256 rightsId,) = ld.getRights(ld.getBaseRightsId(tokenContract, tokenId));
        address owner;
        try ld.ownerOf(rightsId) returns (address retrievedOwner) {
            owner = retrievedOwner;
        } catch {}
        assertTrue(owner != address(0));
        assertTrue(registry.checkDelegateForToken(owner, address(ld), tokenContract, tokenId));
    }

    function invariant_callSummary() public view {
        handler.callSummary();
    }

    function invariant_noncesNotAboveActive() public {
        handler.forAllDelegateTokens(this.rightsNonceLteActive);
        handler.forAllPrincipalTokens(this.rightsNonceLteActive);
    }

    function rightsNonceLteActive(uint256 rightsId) external {
        uint56 nonce = uint56(rightsId);
        (,, Rights memory rights) = ld.getRights(rightsId);
        assertLe(nonce, rights.nonce);
    }

    /// @dev Two existing principal tokens should never have the same base rights Id
    function invariant_onlySinglePrincipal() public {
        handler.forEachExistingPrincipalToken(this.uniquePrincipalBaseRightsId);
    }

    uint256 internal currentPrId;

    function uniquePrincipalBaseRightsId(uint256 prId) external {
        currentPrId = prId;
        handler.forEachExistingPrincipalToken(this.noDuplicatePrBaseRightsId);
        currentPrId = 0;
    }

    function noDuplicatePrBaseRightsId(uint256 prId) external {
        // `forEach` iterates over whole set so need to skip the item itself.
        if (prId != currentPrId) {
            (uint256 baseRightsId1,,) = ld.getRights(prId);
            (uint256 baseRightsId2,,) = ld.getRights(currentPrId);
            assertTrue(baseRightsId1 != baseRightsId2);
        }
    }
}
