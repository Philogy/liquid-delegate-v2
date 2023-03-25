// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {Test} from "forge-std/Test.sol";
import {LibRLP} from "solady/utils/LibRLP.sol";
import {LibString} from "solady/utils/LibString.sol";
import {LiquidDelegateV2, ExpiryType, Rights} from "src/LiquidDelegateV2.sol";
import {PrincipalToken} from "src/PrincipalToken.sol";
import {DelegationRegistry} from "src/DelegationRegistry.sol";
import {MockERC721} from "./mock/MockERC721.sol";

contract LiquidDelegateTest is Test {
    using LibString for uint256;

    // Environment contracts.
    DelegationRegistry registry;
    LiquidDelegateV2 ld;
    PrincipalToken principal;
    MockERC721 token;

    // Test actors.
    address coreDeployer = makeAddr("coreDeployer");
    address ldOwner = makeAddr("ldOwner");

    address seaport = makeAddr("seaport");
    address conduit = makeAddr("conduit");
    address urouter = makeAddr("urouter");

    uint256 internal constant TOTAL_USERS = 100;
    address[TOTAL_USERS] internal users;

    function setUp() public {
        registry = new DelegationRegistry();

        vm.startPrank(coreDeployer);
        ld = new LiquidDelegateV2(
            address(registry),
            seaport,
            conduit,
            urouter,
            LibRLP.computeAddress(coreDeployer, vm.getNonce(coreDeployer) + 1),
            "",
            ldOwner
        );
        principal = new PrincipalToken(
            address(ld),
            seaport,
            conduit,
            urouter
        );
        vm.stopPrank();

        token = new MockERC721(0);

        for (uint256 i; i < TOTAL_USERS; i++) {
            users[i] = makeAddr(string.concat("user", (i + 1).toString()));
        }
    }

    function test_fuzzingCreateRights(
        address tokenOwner,
        address ldTo,
        address notLdTo,
        address principalTo,
        uint256 tokenId,
        bool expiryTypeRelative,
        uint256 time
    ) public {
        vm.assume(tokenOwner != address(0));
        vm.assume(ldTo != address(0));
        vm.assume(principalTo != address(0));
        vm.assume(notLdTo != ldTo);

        (ExpiryType expiryType, uint256 expiry, uint256 expiryValue) = prepareValidExpiry(expiryTypeRelative, time);

        token.mint(tokenOwner, tokenId);
        vm.startPrank(tokenOwner);
        token.setApprovalForAll(address(ld), true);

        uint256 rightsId = ld.create(ldTo, principalTo, address(token), tokenId, expiryType, expiryValue);

        vm.stopPrank();

        assertEq(ld.ownerOf(rightsId), ldTo);
        assertEq(principal.ownerOf(rightsId), principalTo);

        (uint256 baseRightsId, uint256 activeRightsId, Rights memory rights) = ld.getRights(rightsId);
        assertEq(activeRightsId, rightsId);
        assertEq(baseRightsId, ld.getBaseRightsId(address(token), tokenId));
        assertEq(uint256(bytes32(bytes25(bytes32(rightsId)))), baseRightsId);
        assertEq(rights.nonce, 0);
        assertEq(rights.tokenContract, address(token));
        assertEq(rights.tokenId, tokenId);
        assertEq(rights.expiry, expiry);

        assertTrue(registry.checkDelegateForToken(ldTo, address(ld), address(token), tokenId));
        assertFalse(registry.checkDelegateForToken(notLdTo, address(ld), address(token), tokenId));
    }

    function test_fuzzingTransferDelegation(
        address from,
        address to,
        uint256 underlyingTokenId,
        bool expiryTypeRelative,
        uint256 time
    ) public {
        vm.assume(from != address(0));
        vm.assume(to != address(0));

        (ExpiryType expiryType,, uint256 expiryValue) = prepareValidExpiry(expiryTypeRelative, time);
        token.mint(address(ld), underlyingTokenId);

        vm.prank(from);
        uint256 rightsId = ld.mint(from, from, address(token), underlyingTokenId, expiryType, expiryValue);

        vm.prank(from);
        ld.transferFrom(from, to, rightsId);

        assertTrue(registry.checkDelegateForToken(to, address(ld), address(token), underlyingTokenId));

        if (from != to) {
            assertFalse(registry.checkDelegateForToken(from, address(ld), address(token), underlyingTokenId));
        }
    }

    function test_fuzzingCannotCreateWithoutToken(
        address minter,
        uint256 tokenId,
        bool expiryTypeRelative,
        uint256 time
    ) public {
        vm.assume(minter != address(0));
        (ExpiryType expiryType,, uint256 expiryValue) = prepareValidExpiry(expiryTypeRelative, time);

        vm.startPrank(minter);
        vm.expectRevert();
        ld.create(minter, minter, address(token), tokenId, expiryType, expiryValue);
        vm.stopPrank();
    }

    function test_fuzzingCannotCreateWithNonexistentContract(
        address minter,
        address tokenContract,
        uint256 tokenId,
        bool expiryTypeRelative,
        uint256 time
    ) public {
        vm.assume(minter != address(0));
        vm.assume(tokenContract.code.length == 0);

        (ExpiryType expiryType,, uint256 expiryValue) = prepareValidExpiry(expiryTypeRelative, time);

        vm.startPrank(minter);
        vm.expectRevert();
        ld.create(minter, minter, tokenContract, tokenId, expiryType, expiryValue);
        vm.stopPrank();
    }

    function testStaticMetadata() public {
        assertEq(ld.name(), "Liquid Delegate V2");
        assertEq(ld.symbol(), "RIGHTSV2");
        assertEq(ld.version(), "1");
        assertEq(
            ld.DOMAIN_SEPARATOR(),
            keccak256(
                abi.encode(
                    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                    keccak256(bytes(ld.name())),
                    keccak256(bytes(ld.version())),
                    block.chainid,
                    address(ld)
                )
            )
        );
    }

    function randUser(uint256 i) internal view returns (address) {
        return users[bound(i, 0, TOTAL_USERS - 1)];
    }

    function prepareValidExpiry(bool expiryTypeRelative, uint256 time)
        internal
        view
        returns (ExpiryType, uint256, uint256)
    {
        ExpiryType expiryType = expiryTypeRelative ? ExpiryType.Relative : ExpiryType.Absolute;
        time = bound(time, block.timestamp + 1, type(uint40).max);
        uint256 expiryValue = expiryType == ExpiryType.Relative ? time - block.timestamp : time;
        return (expiryType, time, expiryValue);
    }
}
