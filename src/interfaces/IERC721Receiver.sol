// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Receiver hook used by safe managed-position transfers.
interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}
