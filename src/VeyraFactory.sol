// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {VeyraPool} from "./VeyraPool.sol";
import {IVeyraFactory} from "./interfaces/IVeyraFactory.sol";
import {IVeyraPool} from "./interfaces/IVeyraPool.sol";
import {FeeMath} from "./libraries/FeeMath.sol";
import {RangeKey} from "./libraries/RangeKey.sol";

/// @title VeyraFactory
/// @notice Deploys canonical pools and manages protocol-wide fee configuration.
contract VeyraFactory is IVeyraFactory {
    error Unauthorized();
    error ZeroAddress();
    error InvalidTickSpacing(int24 tickSpacing);
    error FeeTierAlreadyEnabled(uint24 feePips);
    error FeeTierNotEnabled(uint24 feePips);
    error PoolAlreadyExists(address token0, address token1, uint24 feePips);
    error UnknownPool(address pool);
    error NotPendingOwner(address caller);

    event OwnershipTransferStarted(address indexed owner, address indexed pendingOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ProtocolFeesWithdrawn(
        address indexed pool, address indexed recipient, uint128 amount0, uint128 amount1
    );

    int24 public constant MAX_TICK_SPACING = 16_384;

    address public override owner;
    address public override pendingOwner;
    address public override protocolFeeRecipient;

    mapping(uint24 feePips => int24 tickSpacing) public override feeAmountTickSpacing;
    mapping(
        address tokenA => mapping(address tokenB => mapping(uint24 feePips => address pool))
    )
        public
        override getPool;
    mapping(address pool => bool registered) public isPool;

    address[] public override allPools;

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor(address initialOwner, address initialProtocolFeeRecipient) {
        if (initialOwner == address(0) || initialProtocolFeeRecipient == address(0)) {
            revert ZeroAddress();
        }

        owner = initialOwner;
        protocolFeeRecipient = initialProtocolFeeRecipient;
        emit OwnershipTransferred(address(0), initialOwner);
        emit ProtocolFeeRecipientUpdated(address(0), initialProtocolFeeRecipient);

        _enableFeeTier(500, 10);
        _enableFeeTier(3000, 60);
        _enableFeeTier(10_000, 200);
    }

    function allPoolsLength() external view override returns (uint256) {
        return allPools.length;
    }

    function createPool(address tokenA, address tokenB, uint24 feePips, uint160 initialSqrtPriceX96)
        external
        override
        returns (address pool)
    {
        (address token0, address token1) = RangeKey.sortTokens(tokenA, tokenB);
        int24 spacing = feeAmountTickSpacing[feePips];
        if (spacing == 0) revert FeeTierNotEnabled(feePips);
        if (getPool[token0][token1][feePips] != address(0)) {
            revert PoolAlreadyExists(token0, token1, feePips);
        }

        bytes32 salt = RangeKey.pool(token0, token1, feePips);
        pool = address(new VeyraPool{salt: salt}(address(this), token0, token1, feePips, spacing));

        getPool[token0][token1][feePips] = pool;
        getPool[token1][token0][feePips] = pool;
        isPool[pool] = true;
        allPools.push(pool);

        IVeyraPool(pool).initialize(initialSqrtPriceX96);
        emit PoolCreated(token0, token1, feePips, spacing, pool);
    }

    function enableFeeTier(uint24 feePips, int24 tickSpacing) external override onlyOwner {
        _enableFeeTier(feePips, tickSpacing);
    }

    function setProtocolFeeRecipient(address recipient) external override onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        address previousRecipient = protocolFeeRecipient;
        protocolFeeRecipient = recipient;
        emit ProtocolFeeRecipientUpdated(previousRecipient, recipient);
    }

    function setPoolProtocolFee(address pool, uint24 protocolFeePips) external override onlyOwner {
        _requirePool(pool);
        FeeMath.validate(protocolFeePips);
        IVeyraPool(pool).setProtocolFee(protocolFeePips);
        emit PoolProtocolFeeUpdated(pool, protocolFeePips);
    }

    function collectPoolProtocolFees(
        address pool,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) external onlyOwner returns (uint128 amount0, uint128 amount1) {
        _requirePool(pool);
        address recipient = protocolFeeRecipient;
        (amount0, amount1) =
            IVeyraPool(pool).collectProtocolFees(recipient, amount0Requested, amount1Requested);
        emit ProtocolFeesWithdrawn(pool, recipient, amount0, amount1);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function cancelOwnershipTransfer() external onlyOwner {
        pendingOwner = address(0);
        emit OwnershipTransferStarted(owner, address(0));
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner(msg.sender);
        address previousOwner = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(previousOwner, msg.sender);
    }

    function computePoolAddress(address tokenA, address tokenB, uint24 feePips)
        external
        view
        returns (address predicted)
    {
        (address token0, address token1) = RangeKey.sortTokens(tokenA, tokenB);
        int24 spacing = feeAmountTickSpacing[feePips];
        if (spacing == 0) revert FeeTierNotEnabled(feePips);

        bytes32 salt = RangeKey.pool(token0, token1, feePips);
        bytes memory creationCode = abi.encodePacked(
            type(VeyraPool).creationCode,
            abi.encode(address(this), token0, token1, feePips, spacing)
        );
        predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(creationCode))
                    )
                )
            )
        );
    }

    function _enableFeeTier(uint24 feePips, int24 tickSpacing) internal {
        FeeMath.validate(feePips);
        if (tickSpacing <= 0 || tickSpacing > MAX_TICK_SPACING) {
            revert InvalidTickSpacing(tickSpacing);
        }
        if (feeAmountTickSpacing[feePips] != 0) revert FeeTierAlreadyEnabled(feePips);

        feeAmountTickSpacing[feePips] = tickSpacing;
        emit FeeTierEnabled(feePips, tickSpacing);
    }

    function _requirePool(address pool) internal view {
        if (!isPool[pool]) revert UnknownPool(pool);
    }
}

