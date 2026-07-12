// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC721Receiver} from "../interfaces/IERC721Receiver.sol";
import {IVeyraFactory} from "../interfaces/IVeyraFactory.sol";
import {IVeyraMintCallback} from "../interfaces/IVeyraMintCallback.sol";
import {IVeyraPool} from "../interfaces/IVeyraPool.sol";
import {IVeyraPositionManager} from "../interfaces/IVeyraPositionManager.sol";
import {IVeyraSwapCallback} from "../interfaces/IVeyraSwapCallback.sol";
import {LiquidityMath} from "../libraries/LiquidityMath.sol";
import {PriceMath} from "../libraries/PriceMath.sol";
import {RangeKey} from "../libraries/RangeKey.sol";
import {SafeTransferLib} from "../libraries/SafeTransferLib.sol";
import {VeyraTypes} from "../types/VeyraTypes.sol";
import {Multicall} from "../utils/Multicall.sol";
import {ReentrancyGuard} from "../utils/ReentrancyGuard.sol";

/// @title VeyraPositionManager
/// @notice ERC-721 ownership and lifecycle orchestration for Veyra liquidity positions.
contract VeyraPositionManager is
    IVeyraPositionManager,
    IVeyraMintCallback,
    IVeyraSwapCallback,
    Multicall,
    ReentrancyGuard
{
    using SafeTransferLib for address;

    error ZeroAddress();
    error TransactionExpired(uint256 deadline);
    error TokenDoesNotExist(uint256 tokenId);
    error InvalidOwner(address owner);
    error InvalidRecipient(address recipient);
    error InvalidOperator(address operator);
    error Unauthorized(uint256 tokenId, address caller);
    error IncorrectOwner(address expected, address actual);
    error UnsafeRecipient(address recipient);
    error PoolNotFound(address token0, address token1, uint24 feePips);
    error InvalidTokenOrder(address token0, address token1);
    error ZeroLiquidity();
    error LiquidityTooLarge(uint128 liquidity);
    error InsufficientLiquidity(uint128 available, uint128 requested);
    error AmountBelowMinimum(uint256 amount0, uint256 amount1, uint256 minimum0, uint256 minimum1);
    error AmountExceedsDesired(
        uint256 amount0, uint256 amount1, uint256 desired0, uint256 desired1
    );
    error InvalidBalanceDelta(int256 amount0, int256 amount1);
    error InvalidCallback(address caller);
    error CallbackNotConsumed();
    error ReleasedLiquidityMismatch(uint128 expected, uint128 actual);
    error RebalanceInputTooLarge(uint256 requested, uint256 available);
    error PositionNotEmpty(uint128 liquidity, uint128 tokensOwed0, uint128 tokensOwed1);

    struct MintCallbackData {
        address pool;
        address payer;
        address token0;
        address token1;
        uint24 feePips;
    }

    struct SwapCallbackData {
        address pool;
        address payer;
        address token0;
        address token1;
        uint24 feePips;
        bool zeroForOne;
    }

    struct AvailableBalances {
        uint256 amount0;
        uint256 amount1;
    }

    struct AddLiquidityData {
        address pool;
        address token0;
        address token1;
        address payer;
        uint24 feePips;
        int24 tickLower;
        int24 tickUpper;
        bytes32 salt;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
    }

    string public constant name = "Veyra Liquidity Position";
    string public constant symbol = "VEYRA-LP";

    address public immutable override factory;
    uint256 public override nextTokenId = 1;

    mapping(uint256 tokenId => address owner) private _owners;
    mapping(address owner => uint256 balance) private _balances;
    mapping(uint256 tokenId => address approved) private _tokenApprovals;
    mapping(address owner => mapping(address operator => bool approved)) private _operatorApprovals;
    mapping(uint256 tokenId => VeyraTypes.ManagedPosition position) private _positions;

    bytes32 private _callbackContext;

    constructor(address factory_) {
        if (factory_ == address(0)) revert ZeroAddress();
        factory = factory_;
    }

    function balanceOf(address owner) public view override returns (uint256) {
        if (owner == address(0)) revert InvalidOwner(owner);
        return _balances[owner];
    }

    function ownerOf(uint256 tokenId) public view override returns (address owner) {
        owner = _owners[tokenId];
        if (owner == address(0)) revert TokenDoesNotExist(tokenId);
    }

    function positions(uint256 tokenId)
        external
        view
        override
        returns (VeyraTypes.ManagedPosition memory)
    {
        _requireToken(tokenId);
        return _positions[tokenId];
    }

    function getApproved(uint256 tokenId) public view override returns (address) {
        _requireToken(tokenId);
        return _tokenApprovals[tokenId];
    }

    function isApprovedForAll(address owner, address operator) public view override returns (bool) {
        return _operatorApprovals[owner][operator];
    }

    function approve(address spender, uint256 tokenId) external override {
        address owner = ownerOf(tokenId);
        if (spender == owner) revert InvalidOperator(spender);
        if (msg.sender != owner && !isApprovedForAll(owner, msg.sender)) {
            revert Unauthorized(tokenId, msg.sender);
        }
        _tokenApprovals[tokenId] = spender;
        emit Approval(owner, spender, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) external override {
        if (operator == msg.sender) revert InvalidOperator(operator);
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function transferFrom(address from, address to, uint256 tokenId) public override {
        if (!_isApprovedOrOwner(msg.sender, tokenId)) revert Unauthorized(tokenId, msg.sender);
        _transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data)
        public
        override
    {
        transferFrom(from, to, tokenId);
        if (!_checkOnERC721Received(msg.sender, from, to, tokenId, data)) {
            revert UnsafeRecipient(to);
        }
    }

    function mint(VeyraTypes.MintPositionParams calldata params)
        external
        override
        nonReentrant
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        _checkDeadline(params.deadline);
        if (params.recipient == address(0)) revert InvalidRecipient(params.recipient);

        tokenId = nextTokenId++;
        AddLiquidityData memory request = _prepareMint(params, tokenId);
        (liquidity, amount0, amount1) = _addLiquidity(request);
        _storePosition(tokenId, request, liquidity);
        _mint(params.recipient, tokenId);
        emit PositionMinted(tokenId, request.pool, liquidity, amount0, amount1);
    }

    function increaseLiquidity(VeyraTypes.IncreaseLiquidityParams calldata params)
        external
        override
        nonReentrant
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        _checkDeadline(params.deadline);
        _requireAuthorized(params.tokenId);
        AddLiquidityData memory request = _prepareIncrease(params);
        (liquidity, amount0, amount1) = _addLiquidity(request);
        _positions[params.tokenId].liquidity += liquidity;
        emit LiquidityIncreased(params.tokenId, liquidity, amount0, amount1);
    }

    function decreaseLiquidity(VeyraTypes.DecreaseLiquidityParams calldata params)
        external
        override
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        _checkDeadline(params.deadline);
        _requireAuthorized(params.tokenId);
        if (params.liquidity == 0) revert ZeroLiquidity();

        VeyraTypes.ManagedPosition storage position = _positions[params.tokenId];
        if (params.liquidity > position.liquidity) {
            revert InsufficientLiquidity(position.liquidity, params.liquidity);
        }

        VeyraTypes.BalanceDelta memory delta = IVeyraPool(position.pool)
            .modifyLiquidity(
                VeyraTypes.ModifyLiquidityParams({
                owner: address(this),
                tickLower: position.tickLower,
                tickUpper: position.tickUpper,
                liquidityDelta: -_toInt128(params.liquidity),
                salt: position.salt
            }),
                ""
            );
        amount0 = _negativeOrZero(delta.amount0, delta);
        amount1 = _negativeOrZero(delta.amount1, delta);
        if (amount0 < params.amount0Min || amount1 < params.amount1Min) {
            revert AmountBelowMinimum(amount0, amount1, params.amount0Min, params.amount1Min);
        }

        position.liquidity -= params.liquidity;
        address recipient = ownerOf(params.tokenId);
        if (amount0 != 0) position.token0.safeTransfer(recipient, amount0);
        if (amount1 != 0) position.token1.safeTransfer(recipient, amount1);
        emit LiquidityDecreased(params.tokenId, params.liquidity, amount0, amount1);
    }

    function collect(VeyraTypes.ManagerCollectParams calldata params)
        external
        override
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        _requireAuthorized(params.tokenId);
        if (params.recipient == address(0)) revert InvalidRecipient(params.recipient);
        VeyraTypes.ManagedPosition memory position = _positions[params.tokenId];

        (uint128 collected0, uint128 collected1) = IVeyraPool(position.pool)
            .collect(
                VeyraTypes.CollectParams({
                owner: address(this),
                recipient: params.recipient,
                tickLower: position.tickLower,
                tickUpper: position.tickUpper,
                amount0Requested: params.amount0Max,
                amount1Requested: params.amount1Max,
                salt: position.salt
            })
            );
        amount0 = collected0;
        amount1 = collected1;
        emit PositionCollected(params.tokenId, params.recipient, amount0, amount1);
    }

    function rebalance(VeyraTypes.RebalanceParams calldata params)
        external
        override
        nonReentrant
        returns (uint128 liquidity, uint256 amount0Used, uint256 amount1Used)
    {
        _checkDeadline(params.deadline);
        _requireAuthorized(params.tokenId);

        VeyraTypes.ManagedPosition memory position = _positions[params.tokenId];
        RangeKey.validateRange(
            params.newTickLower, params.newTickUpper, IVeyraPool(position.pool).tickSpacing()
        );
        bytes32 key = IVeyraPool(position.pool).positionKey(address(this), position.salt);
        (uint128 releasedLiquidity, uint256 released0, uint256 released1) =
            IVeyraPool(position.pool).releaseForRebalance(key, address(this));
        if (releasedLiquidity != position.liquidity) {
            revert ReleasedLiquidityMismatch(position.liquidity, releasedLiquidity);
        }

        AvailableBalances memory available =
            AvailableBalances({amount0: released0, amount1: released1});
        if (params.amountIn != 0) {
            available = _swapRebalance(position, params, available);
        }

        liquidity = _liquidityForAmounts(
            position.pool,
            params.newTickLower,
            params.newTickUpper,
            available.amount0,
            available.amount1
        );
        if (liquidity == 0) revert ZeroLiquidity();

        (amount0Used, amount1Used) = _finalizeRebalance(position, params, available, liquidity);
    }

    function burn(uint256 tokenId) external override nonReentrant {
        _requireAuthorized(tokenId);
        VeyraTypes.ManagedPosition memory position = _positions[tokenId];
        bytes32 key = IVeyraPool(position.pool).positionKey(address(this), position.salt);
        VeyraTypes.PositionState memory state = IVeyraPool(position.pool).positionState(key);
        if (position.liquidity != 0 || state.tokensOwed0 != 0 || state.tokensOwed1 != 0) {
            revert PositionNotEmpty(position.liquidity, state.tokensOwed0, state.tokensOwed1);
        }

        address owner = ownerOf(tokenId);
        delete _positions[tokenId];
        delete _owners[tokenId];
        delete _tokenApprovals[tokenId];
        unchecked {
            --_balances[owner];
        }
        emit Transfer(owner, address(0), tokenId);
    }

    function veyraMintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes calldata data)
        external
        override
    {
        _consumeContext(data);
        MintCallbackData memory decoded = abi.decode(data, (MintCallbackData));
        _validatePool(decoded.pool, decoded.token0, decoded.token1, decoded.feePips);
        if (msg.sender != decoded.pool) revert InvalidCallback(msg.sender);

        _pay(decoded.token0, decoded.payer, msg.sender, amount0Owed);
        _pay(decoded.token1, decoded.payer, msg.sender, amount1Owed);
    }

    function veyraSwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data)
        external
        override
    {
        _consumeContext(data);
        SwapCallbackData memory decoded = abi.decode(data, (SwapCallbackData));
        _validatePool(decoded.pool, decoded.token0, decoded.token1, decoded.feePips);
        if (msg.sender != decoded.pool) revert InvalidCallback(msg.sender);

        if (decoded.zeroForOne) {
            if (amount0Delta <= 0 || amount1Delta > 0) {
                revert InvalidBalanceDelta(amount0Delta, amount1Delta);
            }
            _pay(decoded.token0, decoded.payer, msg.sender, uint256(amount0Delta));
        } else {
            if (amount1Delta <= 0 || amount0Delta > 0) {
                revert InvalidBalanceDelta(amount0Delta, amount1Delta);
            }
            _pay(decoded.token1, decoded.payer, msg.sender, uint256(amount1Delta));
        }
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == 0x01ffc9a7 || interfaceId == 0x80ac58cd
            || interfaceId == type(IVeyraPositionManager).interfaceId;
    }

    function tokenURI(uint256 tokenId) external view returns (string memory) {
        _requireToken(tokenId);
        return string.concat("veyra://position/", _toString(tokenId));
    }

    function _addLiquidity(AddLiquidityData memory request)
        internal
        returns (uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        liquidity = _liquidityForAmounts(
            request.pool,
            request.tickLower,
            request.tickUpper,
            request.amount0Desired,
            request.amount1Desired
        );
        if (liquidity == 0) revert ZeroLiquidity();

        bytes memory data = abi.encode(
            MintCallbackData({
                pool: request.pool,
                payer: request.payer,
                token0: request.token0,
                token1: request.token1,
                feePips: request.feePips
            })
        );
        _callbackContext = keccak256(data);
        VeyraTypes.BalanceDelta memory delta = IVeyraPool(request.pool)
            .modifyLiquidity(
                VeyraTypes.ModifyLiquidityParams({
                owner: address(this),
                tickLower: request.tickLower,
                tickUpper: request.tickUpper,
                liquidityDelta: _toInt128(liquidity),
                salt: request.salt
            }),
                data
            );
        _requireCallbackConsumed();
        amount0 = _positiveOrZero(delta.amount0, delta);
        amount1 = _positiveOrZero(delta.amount1, delta);
        _checkAmounts(
            amount0,
            amount1,
            request.amount0Min,
            request.amount1Min,
            request.amount0Desired,
            request.amount1Desired
        );
    }

    function _prepareMint(VeyraTypes.MintPositionParams calldata params, uint256 tokenId)
        internal
        view
        returns (AddLiquidityData memory request)
    {
        (request.pool, request.token0, request.token1) =
            _resolveOrderedPool(params.token0, params.token1, params.feePips);
        RangeKey.validateRange(
            params.tickLower, params.tickUpper, IVeyraPool(request.pool).tickSpacing()
        );
        request.payer = msg.sender;
        request.feePips = params.feePips;
        request.tickLower = params.tickLower;
        request.tickUpper = params.tickUpper;
        request.salt = keccak256(abi.encode(address(this), tokenId));
        request.amount0Desired = params.amount0Desired;
        request.amount1Desired = params.amount1Desired;
        request.amount0Min = params.amount0Min;
        request.amount1Min = params.amount1Min;
    }

    function _prepareIncrease(VeyraTypes.IncreaseLiquidityParams calldata params)
        internal
        view
        returns (AddLiquidityData memory request)
    {
        VeyraTypes.ManagedPosition memory position = _positions[params.tokenId];
        request.pool = position.pool;
        request.token0 = position.token0;
        request.token1 = position.token1;
        request.payer = msg.sender;
        request.feePips = position.feePips;
        request.tickLower = position.tickLower;
        request.tickUpper = position.tickUpper;
        request.salt = position.salt;
        request.amount0Desired = params.amount0Desired;
        request.amount1Desired = params.amount1Desired;
        request.amount0Min = params.amount0Min;
        request.amount1Min = params.amount1Min;
    }

    function _storePosition(uint256 tokenId, AddLiquidityData memory request, uint128 liquidity)
        internal
    {
        _positions[tokenId] = VeyraTypes.ManagedPosition({
            pool: request.pool,
            token0: request.token0,
            token1: request.token1,
            feePips: request.feePips,
            tickLower: request.tickLower,
            tickUpper: request.tickUpper,
            liquidity: liquidity,
            salt: request.salt
        });
    }

    function _swapRebalance(
        VeyraTypes.ManagedPosition memory position,
        VeyraTypes.RebalanceParams calldata params,
        AvailableBalances memory available
    ) internal returns (AvailableBalances memory) {
        uint256 availableInput = params.zeroForOne ? available.amount0 : available.amount1;
        if (params.amountIn > availableInput) {
            revert RebalanceInputTooLarge(params.amountIn, availableInput);
        }
        if (params.amountIn > uint256(type(int256).max)) {
            revert RebalanceInputTooLarge(params.amountIn, uint256(type(int256).max));
        }

        bytes memory data = abi.encode(
            SwapCallbackData({
                pool: position.pool,
                payer: address(this),
                token0: position.token0,
                token1: position.token1,
                feePips: position.feePips,
                zeroForOne: params.zeroForOne
            })
        );
        _callbackContext = keccak256(data);
        VeyraTypes.BalanceDelta memory delta = IVeyraPool(position.pool)
            .swap(
                VeyraTypes.SwapParams({
                recipient: address(this),
                zeroForOne: params.zeroForOne,
                amountSpecified: int256(params.amountIn),
                sqrtPriceLimitX96: params.sqrtPriceLimitX96
            }),
                data
            );
        _requireCallbackConsumed();

        if (params.zeroForOne) {
            uint256 spent0 = _positive(delta.amount0, delta);
            uint256 received1 = _negative(delta.amount1, delta);
            available.amount0 -= spent0;
            available.amount1 += received1;
        } else {
            uint256 spent1 = _positive(delta.amount1, delta);
            uint256 received0 = _negative(delta.amount0, delta);
            available.amount1 -= spent1;
            available.amount0 += received0;
        }
        return available;
    }

    function _commitRebalance(
        VeyraTypes.ManagedPosition memory position,
        VeyraTypes.RebalanceParams calldata params,
        uint128 liquidity
    ) internal returns (VeyraTypes.BalanceDelta memory delta) {
        bytes32 key = IVeyraPool(position.pool).positionKey(address(this), position.salt);
        bytes memory data = abi.encode(
            MintCallbackData({
                pool: position.pool,
                payer: address(this),
                token0: position.token0,
                token1: position.token1,
                feePips: position.feePips
            })
        );
        _callbackContext = keccak256(data);
        delta = IVeyraPool(position.pool)
            .commitRebalance(key, params.newTickLower, params.newTickUpper, liquidity, data);
        _requireCallbackConsumed();
    }

    function _finalizeRebalance(
        VeyraTypes.ManagedPosition memory position,
        VeyraTypes.RebalanceParams calldata params,
        AvailableBalances memory available,
        uint128 liquidity
    ) internal returns (uint256 amount0Used, uint256 amount1Used) {
        VeyraTypes.BalanceDelta memory delta = _commitRebalance(position, params, liquidity);
        amount0Used = _positiveOrZero(delta.amount0, delta);
        amount1Used = _positiveOrZero(delta.amount1, delta);
        _checkRebalanceAmounts(amount0Used, amount1Used, available, params);
        _refundRebalance(position, params.tokenId, available, amount0Used, amount1Used);
        _updateRange(params.tokenId, params.newTickLower, params.newTickUpper, liquidity);
    }

    function _checkRebalanceAmounts(
        uint256 amount0Used,
        uint256 amount1Used,
        AvailableBalances memory available,
        VeyraTypes.RebalanceParams calldata params
    ) internal pure {
        if (amount0Used > available.amount0 || amount1Used > available.amount1) {
            revert AmountExceedsDesired(
                amount0Used, amount1Used, available.amount0, available.amount1
            );
        }
        if (amount0Used < params.amount0Min || amount1Used < params.amount1Min) {
            revert AmountBelowMinimum(
                amount0Used, amount1Used, params.amount0Min, params.amount1Min
            );
        }
    }

    function _refundRebalance(
        VeyraTypes.ManagedPosition memory position,
        uint256 tokenId,
        AvailableBalances memory available,
        uint256 amount0Used,
        uint256 amount1Used
    ) internal {
        address recipient = ownerOf(tokenId);
        uint256 refund0 = available.amount0 - amount0Used;
        uint256 refund1 = available.amount1 - amount1Used;
        if (refund0 != 0) position.token0.safeTransfer(recipient, refund0);
        if (refund1 != 0) position.token1.safeTransfer(recipient, refund1);
    }

    function _updateRange(uint256 tokenId, int24 newLower, int24 newUpper, uint128 liquidity)
        internal
    {
        VeyraTypes.ManagedPosition storage stored = _positions[tokenId];
        int24 previousLower = stored.tickLower;
        int24 previousUpper = stored.tickUpper;
        stored.tickLower = newLower;
        stored.tickUpper = newUpper;
        stored.liquidity = liquidity;
        emit PositionRebalanced(
            tokenId, previousLower, previousUpper, newLower, newUpper, liquidity
        );
    }

    function _liquidityForAmounts(
        address pool,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0,
        uint256 amount1
    ) internal view returns (uint128) {
        uint160 current = IVeyraPool(pool).slot0().sqrtPriceX96;
        return LiquidityMath.liquidityForAmounts(
            current,
            PriceMath.getSqrtPriceAtTick(tickLower),
            PriceMath.getSqrtPriceAtTick(tickUpper),
            amount0,
            amount1
        );
    }

    function _resolveOrderedPool(address token0, address token1, uint24 feePips)
        internal
        view
        returns (address pool, address canonical0, address canonical1)
    {
        pool = IVeyraFactory(factory).getPool(token0, token1, feePips);
        if (pool == address(0)) revert PoolNotFound(token0, token1, feePips);
        canonical0 = IVeyraPool(pool).token0();
        canonical1 = IVeyraPool(pool).token1();
        if (token0 != canonical0 || token1 != canonical1) {
            revert InvalidTokenOrder(token0, token1);
        }
    }

    function _validatePool(address pool, address token0, address token1, uint24 feePips)
        internal
        view
    {
        if (IVeyraFactory(factory).getPool(token0, token1, feePips) != pool) {
            revert InvalidCallback(msg.sender);
        }
    }

    function _pay(address token, address payer, address recipient, uint256 amount) internal {
        if (amount == 0) return;
        if (payer == address(this)) token.safeTransfer(recipient, amount);
        else token.safeTransferFrom(payer, recipient, amount);
    }

    function _checkAmounts(
        uint256 amount0,
        uint256 amount1,
        uint256 minimum0,
        uint256 minimum1,
        uint256 desired0,
        uint256 desired1
    ) internal pure {
        if (amount0 > desired0 || amount1 > desired1) {
            revert AmountExceedsDesired(amount0, amount1, desired0, desired1);
        }
        if (amount0 < minimum0 || amount1 < minimum1) {
            revert AmountBelowMinimum(amount0, amount1, minimum0, minimum1);
        }
    }

    function _positive(int256 value, VeyraTypes.BalanceDelta memory delta)
        internal
        pure
        returns (uint256)
    {
        if (value <= 0) revert InvalidBalanceDelta(delta.amount0, delta.amount1);
        return uint256(value);
    }

    function _positiveOrZero(int256 value, VeyraTypes.BalanceDelta memory delta)
        internal
        pure
        returns (uint256)
    {
        if (value < 0) revert InvalidBalanceDelta(delta.amount0, delta.amount1);
        return uint256(value);
    }

    function _negative(int256 value, VeyraTypes.BalanceDelta memory delta)
        internal
        pure
        returns (uint256)
    {
        if (value >= 0) revert InvalidBalanceDelta(delta.amount0, delta.amount1);
        return uint256(-value);
    }

    function _negativeOrZero(int256 value, VeyraTypes.BalanceDelta memory delta)
        internal
        pure
        returns (uint256)
    {
        if (value > 0) revert InvalidBalanceDelta(delta.amount0, delta.amount1);
        return value == 0 ? 0 : uint256(-value);
    }

    function _toInt128(uint128 value) internal pure returns (int128) {
        if (value > uint128(type(int128).max)) revert LiquidityTooLarge(value);
        return int128(value);
    }

    function _consumeContext(bytes calldata data) internal {
        bytes32 context = _callbackContext;
        if (context == bytes32(0) || context != keccak256(data)) {
            revert InvalidCallback(msg.sender);
        }
        _callbackContext = bytes32(0);
    }

    function _requireCallbackConsumed() internal view {
        if (_callbackContext != bytes32(0)) revert CallbackNotConsumed();
    }

    function _requireAuthorized(uint256 tokenId) internal view {
        if (!_isApprovedOrOwner(msg.sender, tokenId)) revert Unauthorized(tokenId, msg.sender);
    }

    function _isApprovedOrOwner(address spender, uint256 tokenId) internal view returns (bool) {
        address owner = ownerOf(tokenId);
        return spender == owner || _tokenApprovals[tokenId] == spender
            || _operatorApprovals[owner][spender];
    }

    function _requireToken(uint256 tokenId) internal view {
        if (_owners[tokenId] == address(0)) revert TokenDoesNotExist(tokenId);
    }

    function _mint(address to, uint256 tokenId) internal {
        if (to == address(0)) revert InvalidRecipient(to);
        if (_owners[tokenId] != address(0)) revert InvalidOwner(to);
        _owners[tokenId] = to;
        unchecked {
            ++_balances[to];
        }
        emit Transfer(address(0), to, tokenId);
    }

    function _transfer(address from, address to, uint256 tokenId) internal {
        address owner = ownerOf(tokenId);
        if (owner != from) revert IncorrectOwner(owner, from);
        if (to == address(0)) revert InvalidRecipient(to);

        delete _tokenApprovals[tokenId];
        unchecked {
            --_balances[from];
            ++_balances[to];
        }
        _owners[tokenId] = to;
        emit Approval(from, address(0), tokenId);
        emit Transfer(from, to, tokenId);
    }

    function _checkOnERC721Received(
        address operator,
        address from,
        address to,
        uint256 tokenId,
        bytes memory data
    ) private returns (bool) {
        if (to.code.length == 0) return true;
        try IERC721Receiver(to).onERC721Received(operator, from, tokenId, data) returns (
            bytes4 response
        ) {
            return response == IERC721Receiver.onERC721Received.selector;
        } catch {
            return false;
        }
    }

    function _checkDeadline(uint256 deadline) internal view {
        if (block.timestamp > deadline) revert TransactionExpired(deadline);
    }

    function _toString(uint256 value) private pure returns (string memory result) {
        if (value == 0) return "0";
        uint256 digits;
        uint256 copy = value;
        while (copy != 0) {
            ++digits;
            copy /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            unchecked {
                buffer[--digits] = bytes1(uint8(48 + (value % 10)));
            }
            value /= 10;
        }
        result = string(buffer);
    }
}
