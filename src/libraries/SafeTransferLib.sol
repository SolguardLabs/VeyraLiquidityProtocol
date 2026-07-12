// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20Minimal} from "../interfaces/IERC20Minimal.sol";

/// @title SafeTransferLib
/// @notice Compatibility wrappers for ERC-20 tokens that omit boolean return values.
library SafeTransferLib {
    error TransferFailed(address token, address to, uint256 amount);
    error TransferFromFailed(address token, address from, address to, uint256 amount);
    error ApprovalFailed(address token, address spender, uint256 amount);
    error BalanceQueryFailed(address token, address account);

    function safeTransfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory result) =
            token.call(abi.encodeCall(IERC20Minimal.transfer, (to, amount)));
        if (!success || !_returnedTrue(result)) revert TransferFailed(token, to, amount);
    }

    function safeTransferFrom(address token, address from, address to, uint256 amount) internal {
        (bool success, bytes memory result) =
            token.call(abi.encodeCall(IERC20Minimal.transferFrom, (from, to, amount)));
        if (!success || !_returnedTrue(result)) revert TransferFromFailed(token, from, to, amount);
    }

    function safeApprove(address token, address spender, uint256 amount) internal {
        (bool success, bytes memory result) =
            token.call(abi.encodeCall(IERC20Minimal.approve, (spender, amount)));
        if (!success || !_returnedTrue(result)) revert ApprovalFailed(token, spender, amount);
    }

    /// @notice Sets an allowance, resetting it to zero first when required by the token.
    function forceApprove(address token, address spender, uint256 amount) internal {
        (bool success, bytes memory result) =
            token.call(abi.encodeCall(IERC20Minimal.approve, (spender, amount)));
        if (success && _returnedTrue(result)) return;
        safeApprove(token, spender, 0);
        safeApprove(token, spender, amount);
    }

    function safeBalanceOf(address token, address account) internal view returns (uint256 balance) {
        (bool success, bytes memory result) =
            token.staticcall(abi.encodeCall(IERC20Minimal.balanceOf, (account)));
        if (!success || result.length < 32) revert BalanceQueryFailed(token, account);
        balance = abi.decode(result, (uint256));
    }

    function _returnedTrue(bytes memory result) private pure returns (bool) {
        if (result.length == 0) return true;
        if (result.length < 32) return false;
        return abi.decode(result, (bool));
    }
}
