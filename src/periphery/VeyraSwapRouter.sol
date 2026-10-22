// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IVeyraFactory} from "../interfaces/IVeyraFactory.sol";
import {IVeyraPool} from "../interfaces/IVeyraPool.sol";
import {IVeyraRouter} from "../interfaces/IVeyraRouter.sol";
import {IVeyraSwapCallback} from "../interfaces/IVeyraSwapCallback.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {VeyraTypes} from "../types/VeyraTypes.sol";

/// @title VeyraSwapRouter
/// @notice Executes protected single-pool swaps and settles pool callbacks.
contract VeyraSwapRouter is IVeyraRouter, IVeyraSwapCallback {
    using SafeTransferLib for address;

    error Reentrancy();
    error TransactionExpired(uint256 deadline);
    error ZeroAddress();
    error ZeroAmount();
    error AmountTooLarge();
    error PoolNotFound(address tokenIn, address tokenOut, uint24 feePips);
    error InvalidPoolTokens(address pool);
    error InvalidCallback(address caller);
    error UnexpectedCallbackDelta(int256 amount0Delta, int256 amount1Delta);
    error CallbackNotConsumed();
    error InsufficientOutput(uint256 amountOut, uint256 minimum);
    error ExcessiveInput(uint256 amountIn, uint256 maximum);
    error MulticallFailed(uint256 index, bytes reason);

    struct SwapCallbackData {
        address pool;
        address payer;
        address token0;
        address token1;
        uint24 feePips;
        bool zeroForOne;
    }

    address public immutable override factory;

    uint256 private _lock = 1;
    bytes32 private _callbackContext;

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(address factory_) {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
    }

    function exactInputSingle(VeyraTypes.ExactInputSingleParams calldata params)
        external
        override
        nonReentrant
        returns (uint256 amountOut)
    {
        _checkDeadline(params.deadline);
        if (params.recipient == address(0)) revert ZeroAddress();
        if (params.amountIn == 0) revert ZeroAmount();
        if (params.amountIn > uint256(type(int256).max)) revert AmountTooLarge();

        (address pool, address token0, address token1, bool zeroForOne) =
            _resolvePool(params.tokenIn, params.tokenOut, params.feePips);
        bytes memory callbackData = abi.encode(
            SwapCallbackData({
                pool: pool,
                payer: msg.sender,
                token0: token0,
                token1: token1,
                feePips: params.feePips,
                zeroForOne: zeroForOne
            })
        );

        _callbackContext = keccak256(callbackData);
        VeyraTypes.BalanceDelta memory delta = IVeyraPool(pool)
            .swap(
                VeyraTypes.SwapParams({
                    recipient: params.recipient,
                    zeroForOne: zeroForOne,
                    amountSpecified: int256(params.amountIn),
                    sqrtPriceLimitX96: params.sqrtPriceLimitX96
                }),
                callbackData
            );
        _requireCallbackConsumed();

        amountOut = _outputAmount(delta, zeroForOne);
        if (amountOut < params.amountOutMinimum) {
            revert InsufficientOutput(amountOut, params.amountOutMinimum);
        }
    }

    function exactOutputSingle(VeyraTypes.ExactOutputSingleParams calldata params)
        external
        override
        nonReentrant
        returns (uint256 amountIn)
    {
        _checkDeadline(params.deadline);
        if (params.recipient == address(0)) revert ZeroAddress();
        if (params.amountOut == 0) revert ZeroAmount();
        if (params.amountOut > uint256(type(int256).max)) revert AmountTooLarge();

        (address pool, address token0, address token1, bool zeroForOne) =
            _resolvePool(params.tokenIn, params.tokenOut, params.feePips);
        bytes memory callbackData = abi.encode(
            SwapCallbackData({
                pool: pool,
                payer: msg.sender,
                token0: token0,
                token1: token1,
                feePips: params.feePips,
                zeroForOne: zeroForOne
            })
        );

        _callbackContext = keccak256(callbackData);
        VeyraTypes.BalanceDelta memory delta = IVeyraPool(pool)
            .swap(
                VeyraTypes.SwapParams({
                    recipient: params.recipient,
                    zeroForOne: zeroForOne,
                    amountSpecified: -int256(params.amountOut),
                    sqrtPriceLimitX96: params.sqrtPriceLimitX96
                }),
                callbackData
            );
        _requireCallbackConsumed();

        uint256 actualOutput = _outputAmount(delta, zeroForOne);
        if (actualOutput < params.amountOut) {
            revert InsufficientOutput(actualOutput, params.amountOut);
        }
        amountIn = _inputAmount(delta, zeroForOne);
        if (amountIn > params.amountInMaximum) {
            revert ExcessiveInput(amountIn, params.amountInMaximum);
        }
    }

    function multicall(bytes[] calldata calls) external returns (bytes[] memory results) {
        results = new bytes[](calls.length);
        for (uint256 i; i < calls.length; ++i) {
            (bool success, bytes memory result) = address(this).delegatecall(calls[i]);
            if (!success) revert MulticallFailed(i, result);
            results[i] = result;
        }
    }

    function veyraSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data)
        external
        override
    {
        if (_callbackContext == bytes32(0) || keccak256(data) != _callbackContext) {
            revert InvalidCallback(msg.sender);
        }

        SwapCallbackData memory decoded = abi.decode(data, (SwapCallbackData));
        if (
            msg.sender != decoded.pool
                || IVeyraFactory(factory).getPool(decoded.token0, decoded.token1, decoded.feePips)
                    != msg.sender
        ) {
            revert InvalidCallback(msg.sender);
        }

        _callbackContext = bytes32(0);
        if (decoded.zeroForOne) {
            if (amount0Delta <= 0 || amount1Delta > 0) {
                revert UnexpectedCallbackDelta(amount0Delta, amount1Delta);
            }
            decoded.token0.safeTransferFrom(decoded.payer, msg.sender, uint256(amount0Delta));
        } else {
            if (amount1Delta <= 0 || amount0Delta > 0) {
                revert UnexpectedCallbackDelta(amount0Delta, amount1Delta);
            }
            decoded.token1.safeTransferFrom(decoded.payer, msg.sender, uint256(amount1Delta));
        }
    }

    function _resolvePool(address tokenIn, address tokenOut, uint24 feePips)
        internal
        view
        returns (address pool, address token0, address token1, bool zeroForOne)
    {
        if (tokenIn == address(0) || tokenOut == address(0)) revert ZeroAddress();
        pool = IVeyraFactory(factory).getPool(tokenIn, tokenOut, feePips);
        if (pool == address(0)) revert PoolNotFound(tokenIn, tokenOut, feePips);

        token0 = IVeyraPool(pool).token0();
        token1 = IVeyraPool(pool).token1();
        if (!((tokenIn == token0 && tokenOut == token1)
                    || (tokenIn == token1 && tokenOut == token0))) {
            revert InvalidPoolTokens(pool);
        }
        zeroForOne = tokenIn == token0;
    }

    function _outputAmount(VeyraTypes.BalanceDelta memory delta, bool zeroForOne)
        internal
        pure
        returns (uint256)
    {
        int256 outputDelta = zeroForOne ? delta.amount1 : delta.amount0;
        if (outputDelta >= 0) revert UnexpectedCallbackDelta(delta.amount0, delta.amount1);
        return uint256(-outputDelta);
    }

    function _inputAmount(VeyraTypes.BalanceDelta memory delta, bool zeroForOne)
        internal
        pure
        returns (uint256)
    {
        int256 inputDelta = zeroForOne ? delta.amount0 : delta.amount1;
        if (inputDelta <= 0) revert UnexpectedCallbackDelta(delta.amount0, delta.amount1);
        return uint256(inputDelta);
    }

    function _checkDeadline(uint256 deadline) internal view {
        if (block.timestamp > deadline) revert TransactionExpired(deadline);
    }

    function _requireCallbackConsumed() internal view {
        if (_callbackContext != bytes32(0)) revert CallbackNotConsumed();
    }
}
