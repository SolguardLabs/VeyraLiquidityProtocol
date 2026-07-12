// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20Minimal} from "./interfaces/IERC20Minimal.sol";
import {IVeyraMintCallback} from "./interfaces/IVeyraMintCallback.sol";
import {IVeyraPool} from "./interfaces/IVeyraPool.sol";
import {IVeyraSwapCallback} from "./interfaces/IVeyraSwapCallback.sol";
import {FeeMath} from "./libraries/FeeMath.sol";
import {LiquidityMath} from "./libraries/LiquidityMath.sol";
import {PriceMath} from "./libraries/PriceMath.sol";
import {RangeKey} from "./libraries/RangeKey.sol";
import {SafeTransferLib} from "./libraries/SafeTransferLib.sol";
import {SwapMath} from "./libraries/SwapMath.sol";
import {VeyraTypes} from "./types/VeyraTypes.sol";
import {ReentrancyGuard} from "./utils/ReentrancyGuard.sol";

/// @title VeyraPool
/// @notice Concentrated-liquidity market for one canonical token pair and fee tier.
contract VeyraPool is IVeyraPool, ReentrancyGuard {
    using SafeTransferLib for address;

    error Unauthorized(address caller);
    error AlreadyInitialized();
    error NotInitialized();
    error InvalidRecipient();
    error InvalidLiquidityDelta();
    error InvalidPositionOwner(address caller, address owner);
    error PositionRangeMismatch();
    error PositionNotFound(bytes32 key);
    error PositionInTransition(bytes32 key);
    error PositionNotInTransition(bytes32 key);
    error InsufficientPositionLiquidity(uint128 available, uint128 requested);
    error InsufficientPayment(address token, uint256 expected, uint256 received);
    error InvalidSwapAmount();
    error InvalidPriceLimit(uint160 currentPriceX96, uint160 limitPriceX96);
    error NoLiquidity();
    error ArithmeticOverflow();
    error SwapDidNotProgress();

    event RebalanceReleased(
        bytes32 indexed positionKey,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );
    event RebalanceCommitted(
        bytes32 indexed positionKey,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint128 liquidity,
        uint256 amount0,
        uint256 amount1
    );
    event TickCrossed(int24 indexed tick, uint128 liquidityAfter);

    address public immutable override factory;
    address public immutable override token0;
    address public immutable override token1;
    uint24 public immutable override feePips;
    int24 public immutable override tickSpacing;

    VeyraTypes.Slot0 private _slot0;
    uint128 public override liquidity;
    uint256 public override feeGrowthGlobal0X128;
    uint256 public override feeGrowthGlobal1X128;
    VeyraTypes.ProtocolFees private _protocolFees;

    mapping(int24 tick => VeyraTypes.TickState state) private _ticks;
    mapping(bytes32 key => VeyraTypes.RangeState state) private _ranges;
    mapping(bytes32 key => VeyraTypes.PositionState state) private _positions;
    mapping(int24 tick => uint256 indexPlusOne) private _initializedTickIndex;
    int24[] private _initializedTicks;

    constructor(
        address factory_,
        address token0_,
        address token1_,
        uint24 feePips_,
        int24 tickSpacing_
    ) {
        if (factory_ == address(0) || token0_ == address(0) || token1_ == address(0)) {
            revert InvalidRecipient();
        }
        if (token0_ >= token1_) revert RangeKey.IdenticalTokens();
        FeeMath.validate(feePips_);
        if (tickSpacing_ <= 0) revert RangeKey.InvalidTickSpacing(tickSpacing_);

        factory = factory_;
        token0 = token0_;
        token1 = token1_;
        feePips = feePips_;
        tickSpacing = tickSpacing_;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert Unauthorized(msg.sender);
        _;
    }

    modifier whenInitialized() {
        if (_slot0.sqrtPriceX96 == 0) revert NotInitialized();
        _;
    }

    function poolKey() external view override returns (VeyraTypes.PoolKey memory key) {
        key = VeyraTypes.PoolKey({
            token0: token0, token1: token1, feePips: feePips, tickSpacing: tickSpacing
        });
    }

    function slot0() external view override returns (VeyraTypes.Slot0 memory) {
        return _slot0;
    }

    function protocolFees() external view override returns (VeyraTypes.ProtocolFees memory) {
        return _protocolFees;
    }

    function tickState(int24 tick) external view override returns (VeyraTypes.TickState memory) {
        return _ticks[tick];
    }

    function rangeState(bytes32 key) external view override returns (VeyraTypes.RangeState memory) {
        return _ranges[key];
    }

    function positionState(bytes32 key)
        external
        view
        override
        returns (VeyraTypes.PositionState memory)
    {
        return _positions[key];
    }

    function initializedTicksLength() external view returns (uint256) {
        return _initializedTicks.length;
    }

    function initializedTickAt(uint256 index) external view returns (int24) {
        return _initializedTicks[index];
    }

    function positionKey(address owner, bytes32 salt) public pure override returns (bytes32) {
        return RangeKey.position(owner, salt);
    }

    function feeGrowthInside(int24 tickLower, int24 tickUpper)
        public
        view
        override
        returns (uint256 growth0X128, uint256 growth1X128)
    {
        RangeKey.validateRange(tickLower, tickUpper, tickSpacing);
        return _feeGrowthInside(tickLower, tickUpper);
    }

    function initialize(uint160 sqrtPriceX96) external override onlyFactory {
        if (_slot0.sqrtPriceX96 != 0) revert AlreadyInitialized();
        int24 initialTick = PriceMath.getTickAtSqrtPrice(sqrtPriceX96);
        _slot0 = VeyraTypes.Slot0({
            sqrtPriceX96: sqrtPriceX96, tick: initialTick, protocolFeePips: 0, unlocked: true
        });
        emit Initialized(sqrtPriceX96, initialTick);
    }

    function modifyLiquidity(VeyraTypes.ModifyLiquidityParams calldata params, bytes calldata data)
        external
        override
        nonReentrant
        whenInitialized
        returns (VeyraTypes.BalanceDelta memory delta)
    {
        if (params.owner == address(0)) revert InvalidRecipient();
        if (msg.sender != params.owner) {
            revert InvalidPositionOwner(msg.sender, params.owner);
        }
        if (params.liquidityDelta == 0) revert InvalidLiquidityDelta();
        RangeKey.validateRange(params.tickLower, params.tickUpper, tickSpacing);

        bytes32 key = positionKey(params.owner, params.salt);
        bytes32 rangeId = RangeKey.range(params.tickLower, params.tickUpper);
        VeyraTypes.PositionState storage position = _positions[key];
        if (position.transitioning) revert PositionInTransition(key);

        _preparePosition(position, params, key);
        VeyraTypes.RangeState storage range =
            _syncRange(rangeId, params.tickLower, params.tickUpper);
        _accruePosition(position, range);

        uint128 absoluteLiquidity = _absoluteLiquidity(params.liquidityDelta);
        (uint256 amount0, uint256 amount1) = _amountsForLiquidity(
            params.tickLower, params.tickUpper, absoluteLiquidity, params.liquidityDelta > 0
        );

        if (params.liquidityDelta > 0) {
            bool newPosition = position.liquidity == 0;
            _applyLiquidityDelta(
                params.tickLower, params.tickUpper, params.liquidityDelta, newPosition
            );
            position.liquidity = LiquidityMath.addDelta(position.liquidity, params.liquidityDelta);
            range = _syncRange(rangeId, params.tickLower, params.tickUpper);
            position.feeGrowthInside0LastX128 = range.feeGrowthInside0X128;
            position.feeGrowthInside1LastX128 = range.feeGrowthInside1X128;
            _settleMint(amount0, amount1, data);
            delta =
                VeyraTypes.BalanceDelta({amount0: _toInt256(amount0), amount1: _toInt256(amount1)});
        } else {
            if (absoluteLiquidity > position.liquidity) {
                revert InsufficientPositionLiquidity(position.liquidity, absoluteLiquidity);
            }
            bool closesPosition = absoluteLiquidity == position.liquidity;
            _applyLiquidityDelta(
                params.tickLower, params.tickUpper, params.liquidityDelta, closesPosition
            );
            position.liquidity = LiquidityMath.addDelta(position.liquidity, params.liquidityDelta);
            position.feeGrowthInside0LastX128 = range.feeGrowthInside0X128;
            position.feeGrowthInside1LastX128 = range.feeGrowthInside1X128;
            if (amount0 != 0) token0.safeTransfer(params.owner, amount0);
            if (amount1 != 0) token1.safeTransfer(params.owner, amount1);
            delta = VeyraTypes.BalanceDelta({
                amount0: -_toInt256(amount0), amount1: -_toInt256(amount1)
            });
        }

        emit LiquidityModified(
            key,
            params.owner,
            params.tickLower,
            params.tickUpper,
            params.liquidityDelta,
            delta.amount0,
            delta.amount1
        );
    }

    function releaseForRebalance(bytes32 key, address recipient)
        external
        override
        nonReentrant
        whenInitialized
        returns (uint128 releasedLiquidity, uint256 amount0, uint256 amount1)
    {
        if (recipient == address(0)) revert InvalidRecipient();
        VeyraTypes.PositionState storage position = _positions[key];
        _requirePositionOwner(position, key);
        if (position.transitioning) revert PositionInTransition(key);

        releasedLiquidity = position.liquidity;
        if (releasedLiquidity == 0) revert PositionNotFound(key);
        (amount0, amount1) =
            _amountsForLiquidity(position.tickLower, position.tickUpper, releasedLiquidity, false);

        int128 delta = -int128(releasedLiquidity);
        _applyLiquidityDelta(position.tickLower, position.tickUpper, delta, true);
        position.transitioning = true;
        position.transitionBlock = uint64(block.number);

        if (amount0 != 0) token0.safeTransfer(recipient, amount0);
        if (amount1 != 0) token1.safeTransfer(recipient, amount1);

        emit LiquidityModified(
            key,
            position.owner,
            position.tickLower,
            position.tickUpper,
            delta,
            -_toInt256(amount0),
            -_toInt256(amount1)
        );
        emit RebalanceReleased(
            key, position.tickLower, position.tickUpper, releasedLiquidity, amount0, amount1
        );
    }

    function commitRebalance(
        bytes32 key,
        int24 newTickLower,
        int24 newTickUpper,
        uint128 liquidityDesired,
        bytes calldata data
    )
        external
        override
        nonReentrant
        whenInitialized
        returns (VeyraTypes.BalanceDelta memory delta)
    {
        if (liquidityDesired == 0 || liquidityDesired > uint128(type(int128).max)) {
            revert InvalidLiquidityDelta();
        }
        RangeKey.validateRange(newTickLower, newTickUpper, tickSpacing);
        VeyraTypes.PositionState storage position = _positions[key];
        _requirePositionOwner(position, key);
        if (!position.transitioning) revert PositionNotInTransition(key);
        bytes32 previousRangeId = RangeKey.range(position.tickLower, position.tickUpper);
        VeyraTypes.RangeState storage previousRange =
            _syncRange(previousRangeId, position.tickLower, position.tickUpper);
        _accruePosition(position, previousRange);

        position.liquidity = 0;
        position.tickLower = newTickLower;
        position.tickUpper = newTickUpper;

        bytes32 newRangeId = RangeKey.range(newTickLower, newTickUpper);
        VeyraTypes.RangeState storage newRange = _syncRange(newRangeId, newTickLower, newTickUpper);
        position.feeGrowthInside0LastX128 = newRange.feeGrowthInside0X128;
        position.feeGrowthInside1LastX128 = newRange.feeGrowthInside1X128;

        (uint256 amount0, uint256 amount1) =
            _amountsForLiquidity(newTickLower, newTickUpper, liquidityDesired, true);
        _applyLiquidityDelta(newTickLower, newTickUpper, int128(liquidityDesired), true);
        position.liquidity = liquidityDesired;
        newRange = _syncRange(newRangeId, newTickLower, newTickUpper);
        position.feeGrowthInside0LastX128 = newRange.feeGrowthInside0X128;
        position.feeGrowthInside1LastX128 = newRange.feeGrowthInside1X128;
        position.transitioning = false;
        position.transitionBlock = 0;
        _settleMint(amount0, amount1, data);

        delta = VeyraTypes.BalanceDelta({amount0: _toInt256(amount0), amount1: _toInt256(amount1)});
        emit LiquidityModified(
            key,
            position.owner,
            newTickLower,
            newTickUpper,
            int128(liquidityDesired),
            delta.amount0,
            delta.amount1
        );
        emit RebalanceCommitted(key, newTickLower, newTickUpper, liquidityDesired, amount0, amount1);
    }

    function collect(VeyraTypes.CollectParams calldata params)
        external
        override
        nonReentrant
        whenInitialized
        returns (uint128 amount0, uint128 amount1)
    {
        if (params.recipient == address(0)) revert InvalidRecipient();
        bytes32 key = positionKey(params.owner, params.salt);
        VeyraTypes.PositionState storage position = _positions[key];
        _requirePositionOwner(position, key);
        if (position.transitioning) revert PositionInTransition(key);
        if (position.tickLower != params.tickLower || position.tickUpper != params.tickUpper) {
            revert PositionRangeMismatch();
        }

        bytes32 rangeId = RangeKey.range(params.tickLower, params.tickUpper);
        VeyraTypes.RangeState storage range =
            _syncRange(rangeId, params.tickLower, params.tickUpper);
        _accruePosition(position, range);

        amount0 = params.amount0Requested < position.tokensOwed0
            ? params.amount0Requested
            : position.tokensOwed0;
        amount1 = params.amount1Requested < position.tokensOwed1
            ? params.amount1Requested
            : position.tokensOwed1;
        if (amount0 != 0) {
            position.tokensOwed0 -= amount0;
            token0.safeTransfer(params.recipient, amount0);
        }
        if (amount1 != 0) {
            position.tokensOwed1 -= amount1;
            token1.safeTransfer(params.recipient, amount1);
        }

        emit FeesCollected(key, params.recipient, amount0, amount1);
    }

    function swap(VeyraTypes.SwapParams calldata params, bytes calldata data)
        external
        override
        nonReentrant
        whenInitialized
        returns (VeyraTypes.BalanceDelta memory delta)
    {
        if (params.recipient == address(0)) revert InvalidRecipient();
        if (params.amountSpecified == 0) revert InvalidSwapAmount();
        if (liquidity == 0) revert NoLiquidity();

        uint160 priceLimitX96 = _validatedPriceLimit(params.zeroForOne, params.sqrtPriceLimitX96);
        uint160 currentPriceX96 = _slot0.sqrtPriceX96;
        int24 currentTick = _slot0.tick;
        int256 remaining = params.amountSpecified;
        uint256 totalInput;
        uint256 totalOutput;
        uint256 iteration;

        while (remaining != 0 && currentPriceX96 != priceLimitX96 && liquidity != 0) {
            if (++iteration > _initializedTicks.length + 2) revert SwapDidNotProgress();
            (bool initialized, int24 nextTick) =
                _nextInitializedTick(currentTick, params.zeroForOne);
            uint160 targetPriceX96 = priceLimitX96;
            uint160 boundaryPriceX96;
            if (initialized) {
                boundaryPriceX96 = PriceMath.getSqrtPriceAtTick(nextTick);
                if (params.zeroForOne) {
                    if (boundaryPriceX96 > priceLimitX96) targetPriceX96 = boundaryPriceX96;
                } else if (boundaryPriceX96 < priceLimitX96) {
                    targetPriceX96 = boundaryPriceX96;
                }
            }

            if (targetPriceX96 == currentPriceX96) {
                if (!initialized) break;
                currentTick = _crossTick(nextTick, params.zeroForOne);
                continue;
            }

            (uint160 nextPriceX96, uint256 amountIn, uint256 amountOut, uint256 stepFee) = SwapMath.computeSwapStep(
                currentPriceX96, targetPriceX96, liquidity, remaining, feePips
            );
            if (nextPriceX96 == currentPriceX96 && amountIn == 0 && amountOut == 0) {
                revert SwapDidNotProgress();
            }

            uint256 grossInput = amountIn + stepFee;
            totalInput += grossInput;
            totalOutput += amountOut;
            if (params.amountSpecified > 0) {
                remaining -= _toInt256(grossInput);
                if (remaining < 0) remaining = 0;
            } else {
                remaining += _toInt256(amountOut);
                if (remaining > 0) remaining = 0;
            }

            _accountSwapFee(params.zeroForOne, stepFee);
            currentPriceX96 = nextPriceX96;
            if (initialized && nextPriceX96 == boundaryPriceX96) {
                currentTick = _crossTick(nextTick, params.zeroForOne);
            } else {
                currentTick = PriceMath.getTickAtSqrtPrice(nextPriceX96);
            }
        }

        if (totalInput == 0 || totalOutput == 0) revert SwapDidNotProgress();
        _slot0.sqrtPriceX96 = currentPriceX96;
        _slot0.tick = currentTick;

        if (params.zeroForOne) {
            delta = VeyraTypes.BalanceDelta({
                amount0: _toInt256(totalInput), amount1: -_toInt256(totalOutput)
            });
        } else {
            delta = VeyraTypes.BalanceDelta({
                amount0: -_toInt256(totalOutput), amount1: _toInt256(totalInput)
            });
        }

        _settleSwap(delta, params.recipient, data);
        emit Swap(
            msg.sender,
            params.recipient,
            delta.amount0,
            delta.amount1,
            currentPriceX96,
            liquidity,
            currentTick
        );
    }

    function donate(uint256 amount0, uint256 amount1, bytes calldata data)
        external
        override
        nonReentrant
        whenInitialized
    {
        if (liquidity == 0) revert NoLiquidity();
        if (amount0 == 0 && amount1 == 0) revert InvalidSwapAmount();
        _settleMint(amount0, amount1, data);
        if (amount0 != 0) {
            feeGrowthGlobal0X128 += FeeMath.growthIncrement(amount0, liquidity);
        }
        if (amount1 != 0) {
            feeGrowthGlobal1X128 += FeeMath.growthIncrement(amount1, liquidity);
        }
        emit Donated(msg.sender, amount0, amount1);
    }

    function setProtocolFee(uint24 protocolFeePips) external override onlyFactory {
        FeeMath.validate(protocolFeePips);
        _slot0.protocolFeePips = protocolFeePips;
        emit ProtocolFeeUpdated(protocolFeePips);
    }

    function collectProtocolFees(
        address recipient,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external override onlyFactory nonReentrant returns (uint128 amount0, uint128 amount1) {
        if (recipient == address(0)) revert InvalidRecipient();
        amount0 = amount0Requested < _protocolFees.token0 ? amount0Requested : _protocolFees.token0;
        amount1 = amount1Requested < _protocolFees.token1 ? amount1Requested : _protocolFees.token1;
        if (amount0 != 0) {
            _protocolFees.token0 -= amount0;
            token0.safeTransfer(recipient, amount0);
        }
        if (amount1 != 0) {
            _protocolFees.token1 -= amount1;
            token1.safeTransfer(recipient, amount1);
        }
        emit ProtocolFeesCollected(recipient, amount0, amount1);
    }

    function _preparePosition(
        VeyraTypes.PositionState storage position,
        VeyraTypes.ModifyLiquidityParams calldata params,
        bytes32 key
    ) internal {
        if (position.owner == address(0)) {
            if (params.liquidityDelta < 0) revert PositionNotFound(key);
            position.owner = params.owner;
            position.salt = params.salt;
            position.tickLower = params.tickLower;
            position.tickUpper = params.tickUpper;
        } else {
            if (position.owner != params.owner) {
                revert InvalidPositionOwner(params.owner, position.owner);
            }
            if (position.tickLower != params.tickLower || position.tickUpper != params.tickUpper) {
                revert PositionRangeMismatch();
            }
        }
    }

    function _requirePositionOwner(VeyraTypes.PositionState storage position, bytes32 key)
        internal
        view
    {
        if (position.owner == address(0)) revert PositionNotFound(key);
        if (msg.sender != position.owner) {
            revert InvalidPositionOwner(msg.sender, position.owner);
        }
    }

    function _applyLiquidityDelta(
        int24 tickLower,
        int24 tickUpper,
        int128 delta,
        bool changesPositionCount
    ) internal {
        _updateTick(tickLower, delta, false);
        _updateTick(tickUpper, delta, true);
        bytes32 rangeId = RangeKey.range(tickLower, tickUpper);
        VeyraTypes.RangeState storage range = _ranges[rangeId];
        range.liquidityGross = LiquidityMath.addDelta(range.liquidityGross, delta);
        if (changesPositionCount) {
            if (delta > 0) {
                ++range.positionCount;
            } else if (range.positionCount != 0) {
                --range.positionCount;
            }
        }
        if (_slot0.tick >= tickLower && _slot0.tick < tickUpper) {
            liquidity = LiquidityMath.addDelta(liquidity, delta);
        }
    }

    function _updateTick(int24 tick, int128 delta, bool upper) internal {
        VeyraTypes.TickState storage info = _ticks[tick];
        uint128 beforeGross = info.liquidityGross;
        uint128 afterGross = LiquidityMath.addDelta(beforeGross, delta);
        if (beforeGross == 0 && afterGross != 0) {
            info.initialized = true;
            if (tick <= _slot0.tick) {
                info.feeGrowthOutside0X128 = feeGrowthGlobal0X128;
                info.feeGrowthOutside1X128 = feeGrowthGlobal1X128;
            }
            if (_initializedTickIndex[tick] == 0) {
                _initializedTicks.push(tick);
                _initializedTickIndex[tick] = _initializedTicks.length;
            }
        }
        info.liquidityGross = afterGross;
        info.liquidityNet = upper ? info.liquidityNet - delta : info.liquidityNet + delta;
        if (afterGross == 0) {
            delete _ticks[tick];
            _removeInitializedTick(tick);
        }
    }

    function _removeInitializedTick(int24 tick) internal {
        uint256 indexPlusOne = _initializedTickIndex[tick];
        if (indexPlusOne == 0) return;
        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = _initializedTicks.length - 1;
        if (index != lastIndex) {
            int24 lastTick = _initializedTicks[lastIndex];
            _initializedTicks[index] = lastTick;
            _initializedTickIndex[lastTick] = index + 1;
        }
        _initializedTicks.pop();
        delete _initializedTickIndex[tick];
    }

    function _syncRange(bytes32 rangeId, int24 tickLower, int24 tickUpper)
        internal
        returns (VeyraTypes.RangeState storage range)
    {
        range = _ranges[rangeId];
        (uint256 growth0X128, uint256 growth1X128) = _feeGrowthInside(tickLower, tickUpper);
        range.feeGrowthInside0X128 = growth0X128;
        range.feeGrowthInside1X128 = growth1X128;
        range.lastSyncedBlock = uint64(block.number);
    }

    function _accruePosition(
        VeyraTypes.PositionState storage position,
        VeyraTypes.RangeState storage range
    ) internal {
        if (position.liquidity != 0) {
            uint256 accrued0 = FeeMath.accrued(
                position.liquidity, range.feeGrowthInside0X128, position.feeGrowthInside0LastX128
            );
            uint256 accrued1 = FeeMath.accrued(
                position.liquidity, range.feeGrowthInside1X128, position.feeGrowthInside1LastX128
            );
            position.tokensOwed0 = FeeMath.addOwed(position.tokensOwed0, accrued0);
            position.tokensOwed1 = FeeMath.addOwed(position.tokensOwed1, accrued1);
        }
        position.feeGrowthInside0LastX128 = range.feeGrowthInside0X128;
        position.feeGrowthInside1LastX128 = range.feeGrowthInside1X128;
    }

    function _feeGrowthInside(int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint256 growth0X128, uint256 growth1X128)
    {
        VeyraTypes.TickState storage lower = _ticks[tickLower];
        VeyraTypes.TickState storage upper = _ticks[tickUpper];
        uint256 below0;
        uint256 below1;
        uint256 above0;
        uint256 above1;
        unchecked {
            if (_slot0.tick >= tickLower) {
                below0 = lower.feeGrowthOutside0X128;
                below1 = lower.feeGrowthOutside1X128;
            } else {
                below0 = feeGrowthGlobal0X128 - lower.feeGrowthOutside0X128;
                below1 = feeGrowthGlobal1X128 - lower.feeGrowthOutside1X128;
            }
            if (_slot0.tick < tickUpper) {
                above0 = upper.feeGrowthOutside0X128;
                above1 = upper.feeGrowthOutside1X128;
            } else {
                above0 = feeGrowthGlobal0X128 - upper.feeGrowthOutside0X128;
                above1 = feeGrowthGlobal1X128 - upper.feeGrowthOutside1X128;
            }
            growth0X128 = feeGrowthGlobal0X128 - below0 - above0;
            growth1X128 = feeGrowthGlobal1X128 - below1 - above1;
        }
    }

    function _amountsForLiquidity(
        int24 tickLower,
        int24 tickUpper,
        uint128 amountLiquidity,
        bool roundUp
    ) internal view returns (uint256 amount0, uint256 amount1) {
        uint160 current = _slot0.sqrtPriceX96;
        uint160 lower = PriceMath.getSqrtPriceAtTick(tickLower);
        uint160 upper = PriceMath.getSqrtPriceAtTick(tickUpper);
        if (current <= lower) {
            amount0 = LiquidityMath.amount0Delta(lower, upper, amountLiquidity, roundUp);
        } else if (current < upper) {
            amount0 = LiquidityMath.amount0Delta(current, upper, amountLiquidity, roundUp);
            amount1 = LiquidityMath.amount1Delta(lower, current, amountLiquidity, roundUp);
        } else {
            amount1 = LiquidityMath.amount1Delta(lower, upper, amountLiquidity, roundUp);
        }
    }

    function _settleMint(uint256 amount0, uint256 amount1, bytes calldata data) internal {
        uint256 balance0Before = token0.safeBalanceOf(address(this));
        uint256 balance1Before = token1.safeBalanceOf(address(this));
        IVeyraMintCallback(msg.sender).veyraMintCallback(amount0, amount1, data);
        uint256 received0 = token0.safeBalanceOf(address(this)) - balance0Before;
        uint256 received1 = token1.safeBalanceOf(address(this)) - balance1Before;
        if (received0 < amount0) revert InsufficientPayment(token0, amount0, received0);
        if (received1 < amount1) revert InsufficientPayment(token1, amount1, received1);
    }

    function _settleSwap(
        VeyraTypes.BalanceDelta memory delta,
        address recipient,
        bytes calldata data
    ) internal {
        address inputToken;
        uint256 expectedInput;
        if (delta.amount0 > 0) {
            inputToken = token0;
            expectedInput = uint256(delta.amount0);
        } else {
            inputToken = token1;
            expectedInput = uint256(delta.amount1);
        }
        uint256 balanceBefore = inputToken.safeBalanceOf(address(this));
        if (delta.amount0 < 0) token0.safeTransfer(recipient, uint256(-delta.amount0));
        if (delta.amount1 < 0) token1.safeTransfer(recipient, uint256(-delta.amount1));
        IVeyraSwapCallback(msg.sender).veyraSwapCallback(delta.amount0, delta.amount1, data);
        uint256 received = inputToken.safeBalanceOf(address(this)) - balanceBefore;
        if (received < expectedInput) {
            revert InsufficientPayment(inputToken, expectedInput, received);
        }
    }

    function _accountSwapFee(bool zeroForOne, uint256 totalFee) internal {
        if (totalFee == 0) return;
        (uint256 protocolAmount, uint256 lpAmount) = FeeMath.split(totalFee, _slot0.protocolFeePips);
        if (zeroForOne) {
            _protocolFees.token0 = FeeMath.addOwed(_protocolFees.token0, protocolAmount);
            if (lpAmount != 0) {
                feeGrowthGlobal0X128 += FeeMath.growthIncrement(lpAmount, liquidity);
            }
        } else {
            _protocolFees.token1 = FeeMath.addOwed(_protocolFees.token1, protocolAmount);
            if (lpAmount != 0) {
                feeGrowthGlobal1X128 += FeeMath.growthIncrement(lpAmount, liquidity);
            }
        }
    }

    function _validatedPriceLimit(bool zeroForOne, uint160 requested)
        internal
        view
        returns (uint160 limit)
    {
        limit = requested;
        if (limit == 0) {
            limit = zeroForOne ? PriceMath.MIN_SQRT_PRICE_X96 + 1 : PriceMath.MAX_SQRT_PRICE_X96 - 1;
        }
        if (
            (zeroForOne && (limit >= _slot0.sqrtPriceX96 || limit <= PriceMath.MIN_SQRT_PRICE_X96))
                || (!zeroForOne
                    && (limit <= _slot0.sqrtPriceX96 || limit >= PriceMath.MAX_SQRT_PRICE_X96))
        ) {
            revert InvalidPriceLimit(_slot0.sqrtPriceX96, limit);
        }
    }

    function _nextInitializedTick(int24 currentTick, bool zeroForOne)
        internal
        view
        returns (bool found, int24 nextTick)
    {
        if (zeroForOne) {
            nextTick = PriceMath.MIN_TICK;
            for (uint256 i; i < _initializedTicks.length; ++i) {
                int24 candidate = _initializedTicks[i];
                if (
                    _ticks[candidate].initialized && candidate <= currentTick
                        && (!found || candidate > nextTick)
                ) {
                    found = true;
                    nextTick = candidate;
                }
            }
        } else {
            nextTick = PriceMath.MAX_TICK;
            for (uint256 i; i < _initializedTicks.length; ++i) {
                int24 candidate = _initializedTicks[i];
                if (
                    _ticks[candidate].initialized && candidate > currentTick
                        && (!found || candidate < nextTick)
                ) {
                    found = true;
                    nextTick = candidate;
                }
            }
        }
    }

    function _crossTick(int24 nextTick, bool zeroForOne) internal returns (int24 currentTick) {
        VeyraTypes.TickState storage info = _ticks[nextTick];
        unchecked {
            info.feeGrowthOutside0X128 = feeGrowthGlobal0X128 - info.feeGrowthOutside0X128;
            info.feeGrowthOutside1X128 = feeGrowthGlobal1X128 - info.feeGrowthOutside1X128;
        }
        int128 liquidityDelta = info.liquidityNet;
        if (zeroForOne) liquidityDelta = -liquidityDelta;
        liquidity = LiquidityMath.addDelta(liquidity, liquidityDelta);
        currentTick = zeroForOne ? nextTick - 1 : nextTick;
        emit TickCrossed(nextTick, liquidity);
    }

    function _absoluteLiquidity(int128 value) internal pure returns (uint128) {
        if (value >= 0) return uint128(value);
        return uint128(uint256(-int256(value)));
    }

    function _toInt256(uint256 value) internal pure returns (int256) {
        if (value > uint256(type(int256).max)) revert ArithmeticOverflow();
        return int256(value);
    }
}
