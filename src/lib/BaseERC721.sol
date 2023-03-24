// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {IERC721Receiver} from "openzeppelin-contracts/token/ERC721/IERC721Receiver.sol";
import {IERC721} from "openzeppelin-contracts/token/ERC721/IERC721.sol";
import {Bool256Lib} from "./Bool256Lib.sol";

/// @author philogy <https://github.com/philogy>
/// @author Adapted from solmate's [ERC721](https://github.com/transmissions11/solmate/blob/main/src/tokens/ERC721.sol)
abstract contract BaseERC721 is IERC721 {
    using Bool256Lib for uint256;

    error ZeroAddress();
    error NotAuthorized();
    error WrongFrom();
    error InvalidRecipient();
    error UnsafeRecipient();
    error AlreadyMinted();
    error NotMinted();

    /*//////////////////////////////////////////////////////////////
                         METADATA LOGIC
    //////////////////////////////////////////////////////////////*/

    function name() public view virtual returns (string memory);
    function symbol() public view virtual returns (string memory);
    function tokenURI(uint256 id) public view virtual returns (string memory);

    /*//////////////////////////////////////////////////////////////
                      ERC721 BALANCE/OWNER STORAGE
    //////////////////////////////////////////////////////////////*/

    mapping(uint256 => address) internal $ownerOf;

    mapping(address => uint256) internal $balanceOf;

    function ownerOf(uint256 id) public view virtual returns (address owner) {
        if ((owner = $ownerOf[id]) == address(0)) revert NotMinted();
    }

    function balanceOf(address owner) public view virtual returns (uint256) {
        if (owner == address(0)) revert ZeroAddress();

        return $balanceOf[owner];
    }

    /*//////////////////////////////////////////////////////////////
                         ERC721 APPROVAL STORAGE
    //////////////////////////////////////////////////////////////*/

    mapping(uint256 => address) internal $approved;

    mapping(address => mapping(address => bool)) internal $isApprovedForAll;
    mapping(address => uint256) internal $revokedDefault;

    /// @dev Static immutable variables used to save gas vs. storage array.
    uint256 internal constant TOTAL_DEFAULT_APPROVED = 3;
    address internal immutable DEFAULT_APPROVED1;
    address internal immutable DEFAULT_APPROVED2;
    address internal immutable DEFAULT_APPROVED3;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address defaultApproved1, address defaultApproved2, address defaultApproved3) {
        assert(TOTAL_DEFAULT_APPROVED <= 256);
        DEFAULT_APPROVED1 = defaultApproved1;
        DEFAULT_APPROVED2 = defaultApproved2;
        DEFAULT_APPROVED3 = defaultApproved3;
    }

    /*//////////////////////////////////////////////////////////////
                           ALLOWANCE
    //////////////////////////////////////////////////////////////*/

    function getDefaultApproved() public view returns (address[TOTAL_DEFAULT_APPROVED] memory defaultApproved) {
        defaultApproved[0] = DEFAULT_APPROVED1;
        defaultApproved[1] = DEFAULT_APPROVED2;
        defaultApproved[2] = DEFAULT_APPROVED3;
    }

    function isApprovedOrOwner(address spender, uint256 id) public view virtual returns (bool) {
        (bool approvedOrOwner, address owner) = _isApprovedOrOwner(spender, id);
        if (owner == address(0)) revert NotMinted();
        return approvedOrOwner;
    }

    function isApprovedForAll(address owner, address operator) public view virtual returns (bool) {
        uint256 defaultOperatorIndex = _getDefaultApprovedIndex(operator);
        return defaultOperatorIndex == TOTAL_DEFAULT_APPROVED
            ? $isApprovedForAll[owner][operator]
            : !$revokedDefault[owner].get(defaultOperatorIndex);
    }

    function setApprovalForAll(address operator, bool approved) public virtual {
        uint256 defaultOperatorIndex = _getDefaultApprovedIndex(operator);
        if (defaultOperatorIndex == TOTAL_DEFAULT_APPROVED) {
            $isApprovedForAll[msg.sender][operator] = approved;
        } else {
            $revokedDefault[msg.sender] = $revokedDefault[msg.sender].set(defaultOperatorIndex, !approved);
        }

        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function _isApprovedOrOwner(address spender, uint256 id)
        internal
        view
        virtual
        returns (bool approvedOrOwner, address owner)
    {
        owner = $ownerOf[id];
        approvedOrOwner = spender == owner || isApprovedForAll(owner, spender) || $approved[id] == spender;
    }

    function _getDefaultApprovedIndex(address operator) internal view returns (uint256) {
        address[TOTAL_DEFAULT_APPROVED] memory defaultApproved = getDefaultApproved();
        uint256 i;
        for (; i < TOTAL_DEFAULT_APPROVED;) {
            if (operator == defaultApproved[i]) return i;
            unchecked {
                ++i;
            }
        }
        return i;
    }

    function getApproved(uint256 id) public view returns (address) {
        return $approved[id];
    }

    function approve(address spender, uint256 id) public virtual {
        address owner = $ownerOf[id];

        if (msg.sender != owner && !isApprovedForAll(owner, msg.sender)) revert NotAuthorized();

        $approved[id] = spender;

        emit Approval(owner, spender, id);
    }

    /*//////////////////////////////////////////////////////////////
                              ERC721 LOGIC
    //////////////////////////////////////////////////////////////*/

    function transferFrom(address from, address to, uint256 id) public virtual {
        (bool approvedOrOwner, address owner) = _isApprovedOrOwner(msg.sender, id);
        if (from != owner) revert WrongFrom();
        if (to == address(0)) revert InvalidRecipient();
        if (!approvedOrOwner) revert NotAuthorized();

        // Underflow of the sender's balance is impossible because we check for
        // ownership above and the recipient's balance can't realistically overflow.
        unchecked {
            $balanceOf[from]--;

            $balanceOf[to]++;
        }

        $ownerOf[id] = to;

        delete $approved[id];

        emit Transfer(from, to, id);
    }

    function safeTransferFrom(address from, address to, uint256 id) public virtual {
        transferFrom(from, to, id);
        _checkReceiver(to, from, id, "");
    }

    function safeTransferFrom(address from, address to, uint256 id, bytes calldata data) public virtual {
        transferFrom(from, to, id);
        _checkReceiver(to, from, id, data);
    }

    /*//////////////////////////////////////////////////////////////
                              ERC165 LOGIC
    //////////////////////////////////////////////////////////////*/

    function supportsInterface(bytes4 interfaceId) public view virtual returns (bool) {
        return interfaceId == 0x01ffc9a7 // ERC165 Interface ID for ERC165
            || interfaceId == 0x80ac58cd // ERC165 Interface ID for ERC721
            || interfaceId == 0x5b5e139f; // ERC165 Interface ID for ERC721Metadata
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL MINT/BURN LOGIC
    //////////////////////////////////////////////////////////////*/

    function _mint(address to, uint256 id) internal virtual {
        if (to == address(0)) revert InvalidRecipient();

        if ($ownerOf[id] != address(0)) revert AlreadyMinted();

        // Counter overflow is incredibly unrealistic.
        unchecked {
            $balanceOf[to]++;
        }

        $ownerOf[id] = to;

        emit Transfer(address(0), to, id);
    }

    function _burn(uint256 id) internal virtual {
        address owner = $ownerOf[id];

        if (owner == address(0)) revert NotMinted();

        // Ownership check above ensures no underflow.
        unchecked {
            $balanceOf[owner]--;
        }

        delete $ownerOf[id];

        delete $approved[id];

        emit Transfer(owner, address(0), id);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL SAFE MINT LOGIC
    //////////////////////////////////////////////////////////////*/

    function _safeMint(address to, uint256 id) internal virtual {
        _mint(to, id);
        _checkReceiver(to, address(0), id, "");
    }

    function _safeMint(address to, uint256 id, bytes memory data) internal virtual {
        _mint(to, id);
        _checkReceiver(to, address(0), id, data);
    }

    function _checkReceiver(address to, address from, uint256 id, bytes memory data) internal virtual {
        if (
            to.code.length != 0
                && IERC721Receiver(to).onERC721Received(msg.sender, from, id, data)
                    != IERC721Receiver.onERC721Received.selector
        ) {
            revert UnsafeRecipient();
        }
    }
}
