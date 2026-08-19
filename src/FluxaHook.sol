// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

import {BaseHook} from "./vendor/BaseHook.sol";
import {IFluxaHook} from "./interfaces/IFluxaHook.sol";
import {FluxaLPShares} from "./FluxaLPShares.sol";

import {IChronicleOracle} from "./interfaces/IChronicleOracle.sol";
import {IERC8004Registry, IERC7857Agent} from "./interfaces/IERC8004Registry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract FluxaHook is BaseHook, IFluxaHook, IUnlockCallback, Ownable, ReentrancyGuardTransient {
    using PoolIdLibrary for PoolKey;
    using Hooks for IHooks;
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;

    uint24  public constant BASE_FEE              = 3000;
    uint256 public constant REPUTATION_THRESHOLD  = 50;
    uint256 public constant STALENESS_GUARD       = 1 hours;
    uint256 public constant AUCTION_COMMIT_WINDOW = 1 hours;
    uint256 public constant AUCTION_REVEAL_WINDOW = 30 minutes;
    uint24  private constant OVERRIDE_FEE_FLAG    = 0x400000;

    IChronicleOracle public immutable chronicle;
    IERC8004Registry public immutable reputationRegistry;
    IERC7857Agent    public immutable agentNft;

    mapping(PoolId => RWAInstrument) private _instruments;
    mapping(PoolId => bool)          private _instrumentRegistered;
    mapping(PoolId => PoolState)     private _poolState;
    mapping(PoolId => address)       public  poolAgent;
    mapping(PoolId => Auction)       private _auctions;
    mapping(PoolId => mapping(address => mapping(bytes32 => bool))) public bids;
    mapping(PoolId => mapping(address => uint256))  public bidAmounts;
    mapping(PoolId => uint256) public cumulativeYield;

    mapping(PoolId => FluxaLPShares) public lpShares;
    mapping(PoolId => uint256) public totalLiquidity0;
    mapping(PoolId => uint256) public totalLiquidity1;

    bytes private _callbackDataCache;

    constructor(
        IPoolManager _poolManager,
        IChronicleOracle _chronicle,
        IERC8004Registry _reputationRegistry,
        IERC7857Agent _agentNft,
        address initialOwner
    ) BaseHook(_poolManager) Ownable(initialOwner) {
        chronicle = _chronicle;
        reputationRegistry = _reputationRegistry;
        agentNft = _agentNft;

        IHooks(address(this)).validateHookPermissions(
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: true,
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: true,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: true,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            })
        );
    }

    function getHookPermissions() public pure override returns (BaseHook.HooksPermissions memory) {
        return BaseHook.HooksPermissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function viewInstrument(PoolId id) external view returns (RWAInstrument memory) {
        return _instruments[id];
    }

    function viewPoolState(PoolId id) external view returns (PoolState) {
        return _poolState[id];
    }

    function viewAuction(PoolId id) external view returns (Auction memory) {
        return _auctions[id];
    }

    function registerInstrument(PoolId poolId, RWAInstrument calldata instrument) external onlyOwner {
        _instruments[poolId] = instrument;
        _instrumentRegistered[poolId] = true;
        _poolState[poolId] = PoolState.Normal;
        if (address(lpShares[poolId]) == address(0)) {
            lpShares[poolId] = new FluxaLPShares(address(this));
        }
        emit InstrumentRegistered(poolId, instrument.token, instrument.riskTier, instrument.illiquid, instrument.maturityTs);
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24)
        external
        view
        override
        onlyPoolManager
        returns (bytes4)
    {
        PoolId id = key.toId();
        if (!_instrumentRegistered[id]) revert InstrumentNotRegistered(id);
        return BaseHook.afterInitialize.selector;
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external view override onlyPoolManager returns (bytes4) {
        revert("FluxaHook: use addLiquidity() instead");
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external view override onlyPoolManager returns (bytes4) {
        PoolId id = key.toId();
        if (_poolState[id] == PoolState.Distress) {
            revert InvalidState(id, _poolState[id], PoolState.Normal);
        }
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    struct CallbackData {
        address sender;
        IERC20 token0;
        IERC20 token1;
        uint256 amount0;
        uint256 amount1;
        PoolId poolId;
    }

    function addLiquidity(
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        address sender
    ) external nonReentrant returns (uint256 shares) {
        PoolId poolId = key.toId();
        if (!_instrumentRegistered[poolId]) revert InstrumentNotRegistered(poolId);
        if (_poolState[poolId] != PoolState.Normal) {
            revert InvalidState(poolId, _poolState[poolId], PoolState.Normal);
        }

        uint256 totalLiq0 = totalLiquidity0[poolId];
        uint256 totalLiq1 = totalLiquidity1[poolId];
        uint256 totalSupply = address(lpShares[poolId]) != address(0) ? lpShares[poolId].totalSupply() : 0;

        if (totalSupply == 0) {
            shares = Math.sqrt(amount0 * amount1);
            require(shares > 0, "FluxaHook: zero shares");
        } else {
            shares = Math.min(
                (amount0 * totalSupply) / totalLiq0,
                (amount1 * totalSupply) / totalLiq1
            );
            require(shares > 0, "FluxaHook: insufficient amounts");
        }

        _callbackDataCache = abi.encode(CallbackData({
            sender: sender,
            token0: IERC20(Currency.unwrap(key.currency0)),
            token1: IERC20(Currency.unwrap(key.currency1)),
            amount0: amount0,
            amount1: amount1,
            poolId: poolId
        }));
        poolManager.unlock(abi.encode(uint8(1)));

        totalLiquidity0[poolId] += amount0;
        totalLiquidity1[poolId] += amount1;
        lpShares[poolId].mint(sender, shares);

        emit AddLiquidity(poolId, sender, amount0, amount1, shares);
    }

    function unlockCallback(bytes calldata kind) external override onlyPoolManager returns (bytes memory) {
        uint8 k = kind.length >= 32 ? abi.decode(kind, (uint8)) : 0;
        if (k == 1) {
            return _handleAddLiquidity();
        } else if (k == 2) {
            return _handleRemoveLiquidity();
        }
        revert("FluxaHook: unknown callback kind");
    }

    function _handleAddLiquidity() internal returns (bytes memory) {
        CallbackData memory data = abi.decode(_callbackDataCache, (CallbackData));

        data.token0.safeTransferFrom(data.sender, address(this), data.amount0);
        data.token1.safeTransferFrom(data.sender, address(this), data.amount1);

        Currency c0 = Currency.wrap(address(data.token0));
        Currency c1 = Currency.wrap(address(data.token1));

        data.token0.forceApprove(address(poolManager), data.amount0);
        data.token1.forceApprove(address(poolManager), data.amount1);

        c0.settle(poolManager, address(this), data.amount0, false);
        c1.settle(poolManager, address(this), data.amount1, false);

        c0.take(poolManager, address(this), data.amount0, true);
        c1.take(poolManager, address(this), data.amount1, true);

        return "";
    }

    function _handleRemoveLiquidity() internal returns (bytes memory) {
        RemoveCallbackData memory data = abi.decode(_callbackDataCache, (RemoveCallbackData));

        Currency c0 = data.poolKey.currency0;
        Currency c1 = data.poolKey.currency1;

        c0.settle(poolManager, address(this), data.amount0, true);
        c1.settle(poolManager, address(this), data.amount1, true);

        c0.take(poolManager, data.recipient, data.amount0, false);
        c1.take(poolManager, data.recipient, data.amount1, false);

        return "";
    }

    function removeLiquidity(
        PoolKey calldata key,
        uint256 shares
    ) external nonReentrant returns (uint256 amount0, uint256 amount1) {
        PoolId poolId = key.toId();
        uint256 totalSupply = lpShares[poolId].totalSupply();
        require(totalSupply > 0, "FluxaHook: no liquidity");
        require(shares > 0, "FluxaHook: zero shares");

        amount0 = (shares * totalLiquidity0[poolId]) / totalSupply;
        amount1 = (shares * totalLiquidity1[poolId]) / totalSupply;

        lpShares[poolId].burnFrom(msg.sender, shares);

        totalLiquidity0[poolId] -= amount0;
        totalLiquidity1[poolId] -= amount1;

        _callbackDataCache = abi.encode(RemoveCallbackData({
            poolKey: key,
            recipient: msg.sender,
            amount0: amount0,
            amount1: amount1
        }));
        poolManager.unlock(abi.encode(uint8(2)));

        emit RemoveLiquidity(poolId, msg.sender, amount0, amount1, shares);
    }

    struct RemoveCallbackData {
        PoolKey poolKey;
        address recipient;
        uint256 amount0;
        uint256 amount1;
    }

    function beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId id = key.toId();
        RWAInstrument storage inst = _instruments[id];

        if (_poolState[id] == PoolState.Distress) {
            revert InvalidState(id, _poolState[id], PoolState.Normal);
        }

        if (inst.maturityTs > 0 && block.timestamp >= inst.maturityTs) {
            _setDistress(id, PoolState.Distress);
            revert OracleDefaulted(id);
        }

        if (chronicle.isDefaulted(inst.token) || chronicle.isUnbacked(inst.token)) {
            _setDistress(id, PoolState.Distress);
            revert OracleDefaulted(id);
        }

        if (!inst.illiquid) {
            return _modeASwap(key, params);
        }

        if (hookData.length >= 64) {
            (bytes calldata proof, int128 hookDeltaSpecified) = _extractModeBData(hookData);
            (bool valid, uint256 aiPrice) = chronicle.verifyAttestation(proof);
            if (valid && aiPrice > 0) {
                int128 amtOut;
                if (params.amountSpecified < 0) {
                    uint256 absSpec = uint256(-params.amountSpecified);
                    uint256 out = (absSpec * aiPrice) / 1e18;
                    amtOut = _safeInt128(int256(out));
                } else {
                    uint256 absSpec = uint256(params.amountSpecified);
                    uint256 out = (absSpec * aiPrice) / 1e18;
                    amtOut = -_safeInt128(int256(out));
                }
                BeforeSwapDelta delta = toBeforeSwapDelta(amtOut, hookDeltaSpecified);
                return (BaseHook.beforeSwap.selector, delta, BASE_FEE);
            }
        }

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, BASE_FEE);
    }

    function _modeASwap(
        PoolKey calldata key,
        SwapParams calldata params
    ) internal returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId id = key.toId();
        RWAInstrument storage inst = _instruments[id];

        (, uint256 updateTs) = chronicle.readPrice(inst.token);
        if (block.timestamp - updateTs >= STALENESS_GUARD) revert OracleStale(id);

        uint256 amountInOutPositive = params.amountSpecified > 0
            ? uint256(params.amountSpecified)
            : uint256(-params.amountSpecified);

        uint256 fee = (amountInOutPositive * BASE_FEE) / 1_000_000;
        uint256 netAmount = amountInOutPositive - fee;

        int128 deltaSpecified = int128(-params.amountSpecified);
        int128 deltaUnspecified;
        if (params.amountSpecified < 0) {
            deltaUnspecified = int128(int256(int256(params.amountSpecified) + int256(fee)));
        } else {
            deltaUnspecified = int128(int256(int256(params.amountSpecified) - int256(fee)));
        }

        BeforeSwapDelta beforeSwapDelta = toBeforeSwapDelta(deltaSpecified, deltaUnspecified);

        if (params.zeroForOne) {
            key.currency0.take(poolManager, address(this), amountInOutPositive, true);
            key.currency1.settle(poolManager, address(this), netAmount, true);
        } else {
            key.currency1.take(poolManager, address(this), amountInOutPositive, true);
            key.currency0.settle(poolManager, address(this), netAmount, true);
        }

        cumulativeYield[id] += fee;

        return (BaseHook.beforeSwap.selector, beforeSwapDelta, 0);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta delta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        PoolId id = key.toId();

        emit HookSwap(
            address(poolManager),
            id,
            sender,
            _safeInt128(int256(delta.amount0())),
            _safeInt128(int256(delta.amount1())),
            ""
        );

        return (BaseHook.afterSwap.selector, 0);
    }

    function setDistress(PoolId poolId, PoolState newState) external {
        require(
            msg.sender == owner() || msg.sender == poolAgent[poolId],
            "NotAuthorized"
        );
        require(newState == PoolState.Distress || newState == PoolState.Normal, "InvalidTarget");
        _setDistress(poolId, newState);
    }

    function commitBid(PoolId poolId, bytes32 commitHash) external nonReentrant {
        Auction storage auc = _auctions[poolId];
        if (_poolState[poolId] != PoolState.Distress) {
            revert InvalidState(poolId, _poolState[poolId], PoolState.Distress);
        }
        if (!auc.active) {
            auc.active = true;
            auc.commitDeadline = block.timestamp + AUCTION_COMMIT_WINDOW;
            auc.revealDeadline = auc.commitDeadline + AUCTION_REVEAL_WINDOW;
        }
        if (block.timestamp > auc.commitDeadline) revert CommitDeadlinePassed(poolId);
        bids[poolId][msg.sender][commitHash] = true;
        emit BidCommitted(poolId, msg.sender);
    }

    function revealBid(PoolId poolId, uint256 amount, bytes32 nonce) external nonReentrant {
        Auction storage auc = _auctions[poolId];
        if (!auc.active) revert AuctionNotActive(poolId);
        if (block.timestamp <= auc.commitDeadline) revert("CommitPhase");
        if (block.timestamp > auc.revealDeadline) revert RevealDeadlinePassed(poolId);
        bytes32 commitHash = keccak256(abi.encodePacked(amount, nonce));
        if (!bids[poolId][msg.sender][commitHash]) revert InvalidReveal(poolId, msg.sender);
        bidAmounts[poolId][msg.sender] = amount;
        if (amount > auc.highestAmount) {
            auc.highestAmount = amount;
            auc.highestBidder = msg.sender;
            auc.highestBidHash = commitHash;
        }
        emit BidRevealed(poolId, msg.sender, amount);
    }

    function settleAuction(PoolId poolId) external nonReentrant {
        Auction storage auc = _auctions[poolId];
        if (!auc.active) revert AuctionNotActive(poolId);
        if (block.timestamp <= auc.revealDeadline) revert("RevealPhase");
        if (auc.highestBidder == address(0)) revert NoValidBids(poolId);
        address winner = auc.highestBidder;
        uint256 amount = auc.highestAmount;
        delete _auctions[poolId];
        _setDistress(poolId, PoolState.Resolution);
        emit AuctionSettled(poolId, winner, amount);
        _setDistress(poolId, PoolState.Normal);
    }

    function _setDistress(PoolId poolId, PoolState newState) internal {
        PoolState oldState = _poolState[poolId];
        if (oldState == newState) return;
        _poolState[poolId] = newState;
        emit PoolStateChanged(poolId, oldState, newState);
    }

    function _safeInt128(int256 x) internal pure returns (int128) {
        if (x > type(int128).max) return type(int128).max;
        if (x < type(int128).min) return type(int128).min;
        return int128(x);
    }

    function _extractModeBData(bytes calldata hookData)
        internal
        pure
        returns (bytes calldata proof, int128 hookDeltaSpecified)
    {
        uint256 proofLen;
        assembly { proofLen := calldataload(hookData.offset) }
        proof = hookData[32:32 + proofLen];
        hookDeltaSpecified = abi.decode(hookData[32 + proofLen:], (int128));
    }

    receive() external payable {}
}
