// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";

import {BaseHook} from "./vendor/BaseHook.sol";
import {IFluxaHook} from "./interfaces/IFluxaHook.sol";
import {FluxaLPShares} from "./FluxaLPShares.sol";
import {AgentPricing} from "./libraries/AgentPricing.sol";

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
    uint256 public constant MODE_C_FEE_BPS        = 200; // 2% auction fee
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

    mapping(PoolId => PoolKey) private _poolKeys;

    // Cache last attested price for Mode B quote function (Tao self-integration)
    mapping(PoolId => uint256) public lastAttestedPrice;
    mapping(PoolId => uint256) public lastAttestationTimestamp;

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

    function registerInstrument(PoolId poolId, RWAInstrument calldata instrument, PoolKey calldata key) external onlyOwner {
        _instruments[poolId] = instrument;
        _poolKeys[poolId] = key;
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
        } else if (k == 3) {
            return _handleModeCSettlement();
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

    function _handleModeCSettlement() internal returns (bytes memory) {
        SettlementCallbackData memory data = abi.decode(_callbackDataCache, (SettlementCallbackData));

        Currency c0 = data.poolKey.currency0;
        Currency c1 = data.poolKey.currency1;

        // Step 1: Transfer winner's USDC (token1) from hook to PM, mint USDC claim to hook
        IERC20(Currency.unwrap(c1)).approve(address(poolManager), data.bidAmount);
        c1.settle(poolManager, address(this), data.bidAmount, false);
        c1.take(poolManager, address(this), data.bidAmount, true);

        // Step 2: Transfer hook's RWA claims (token0) to winner via PM (ERC6909)
        uint256 rwaClaimId = c0.toId();
        uint256 rwaBalance = poolManager.balanceOf(address(this), rwaClaimId);
        if (rwaBalance > 0) {
            poolManager.approve(address(this), rwaClaimId, rwaBalance);
            poolManager.transferFrom(address(this), data.winner, rwaClaimId, rwaBalance);
        }

        return "";
    }

    struct SettlementCallbackData {
        PoolKey poolKey;
        address winner;
        uint256 bidAmount;
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

        return _modeBSwap(key, params, hookData, id);
    }

    function _modeBSwap(
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata hookData,
        PoolId id
    ) internal returns (bytes4, BeforeSwapDelta, uint24) {
        // Mode B: exact-input only. For exact output, fall back to Mode A (oracle price).
        if (params.amountSpecified >= 0) {
            return _modeASwap(key, params);
        }

        // hookData format: abi.encode(bytes proof)
        // Fallback to Mode A if data missing or attestation invalid
        if (hookData.length < 64) {
            return _modeASwap(key, params);
        }

        bytes calldata proof = _extractModeBProof(hookData);

        // Verify TEE attestation from Chronicle
        (bool valid, uint256 aiPrice) = chronicle.verifyAttestation(proof);
        if (!valid || aiPrice == 0) {
            return _modeASwap(key, params);
        }

        // Use AgentPricing library to compute swap at AI-inferred price
        // NOTE: AgentPricing.computeSwap makes external calls to poolManager.settle/take,
        // but these are calls to the trusted PoolManager (immutable), not user-controlled contracts.
        // CEI pattern is maintained: state updates below, event emit (not external call) after.
        AgentPricing.SwapResult memory result = AgentPricing.computeSwap(
            params, key, aiPrice, poolManager
        );

        // State updates after external call (CEI: Interactions before Effects would not apply
        // here as computeSwap returns a struct, and no external calls follow these writes).
        // Cache attested price for deterministic quote function (Tao self-integration)
        lastAttestedPrice[id] = aiPrice;
        lastAttestationTimestamp[id] = block.timestamp;

        // Track yield + emit Mode B event (event emission, not an external call — safe after writes)
        cumulativeYield[id] += result.feeAmount;
        emit ModeBSwap(id, aiPrice, result.grossOutput, result.feeAmount);

        return (BaseHook.beforeSwap.selector, result.delta, 0);
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

        // Dynamic fee: BASE_FEE + riskTier * 10bps (per PRD §5 Mode A)
        // riskTier 1 = 0.4%, riskTier 2 = 0.5%, riskTier 3 = 0.6% (max 1,000,000 cap)
        uint256 dynamicFee = BASE_FEE + (inst.riskTier * 1000);
        uint256 fee = (amountInOutPositive * dynamicFee) / 1_000_000;
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

        // Calculate auction fee (2% MODE_C_FEE_BPS) — goes to LP appreciation
        uint256 fee = (amount * MODE_C_FEE_BPS) / 10000;

        // Pull USDC from winner via transferFrom (winner must approve before bidding)
        PoolKey storage key = _poolKeys[poolId];
        Currency c1 = key.currency1; // USDC
        address token1Addr = Currency.unwrap(c1);
        IERC20(token1Addr).safeTransferFrom(winner, address(this), amount);

        // State: Distress -> Resolution (auction in progress)
        _setDistress(poolId, PoolState.Resolution);

        // Set callback data for Mode C PM operations
        _callbackDataCache = abi.encode(SettlementCallbackData({
            poolKey: key,
            winner: winner,
            bidAmount: amount
        }));
        poolManager.unlock(abi.encode(uint8(3)));

        // Fee accounting: cumulativeYield++ (LP shares appreciates automatically)
        cumulativeYield[poolId] += fee;

        // Emit settlement details (winner, amount, fee, net-to-LPs)
        emit AuctionSettled(poolId, winner, amount, fee, amount - fee);

        // State: Resolution -> Normal (pool reopens)
        _setDistress(poolId, PoolState.Normal);

        // Cleanup auction storage
        delete _auctions[poolId];
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

    function _extractModeBProof(bytes calldata hookData)
        internal
        pure
        returns (bytes calldata proof)
    {
        // abi.encode(bytes memory) format: [offset (32 bytes)][length (32 bytes)][data (padded)]
        uint256 dataOffset;
        assembly { dataOffset := calldataload(hookData.offset) }
        // dataOffset is typically 32 for single-element encode
        uint256 dataLen;
        assembly { dataLen := calldataload(add(hookData.offset, dataOffset)) }
        uint256 dataStart = dataOffset + 32;
        proof = hookData[dataStart : dataStart + dataLen];
    }

    // ==========================================================================
    //  TAO SELF-INTEGRATION: deterministic quote + metadata
    //  Tao (Rust library, ~20% CoW Swap mainnet + ~40% CoW Base flow) calls
    //  these view functions via substreams indexing to discover + price liquidity.
    //  Reference: Incubator-Maps/T08 - How to Win Orderflow
    // ==========================================================================

    /// @notice Deterministic quote for Tao router/solver integration
    /// @dev View function, deterministic (no timestamp dependence in pure computation path)
    /// Mode A: uses Chronicle oracle price (last known, view-call is deterministic)
    /// Mode B (illiquid): uses cached lastAttestedPrice (updated on each successful swap)
    /// Mode C (distress): reverts (auction in progress, prices undefined)
    /// @param poolId The pool to quote
    /// @param inputAmount Absolute input amount (uint256, positive)
    /// @param zeroForOne Direction: true sells token0 (RWA) for token1 (USDC), false opposite
    /// @return outputAmount Amount of output token after fee (uint256)
    /// @return feeAmount Amount of fee deducted (uint256)
    function quote(
        PoolId poolId,
        uint256 inputAmount,
        bool zeroForOne
    ) external view returns (uint256 outputAmount, uint256 feeAmount) {
        if (!_instrumentRegistered[poolId]) revert InstrumentNotRegistered(poolId);
        if (_poolState[poolId] == PoolState.Distress) {
            revert InvalidState(poolId, _poolState[poolId], PoolState.Normal);
        }
        RWAInstrument storage inst = _instruments[poolId];

        uint256 price;
        if (!inst.illiquid) {
            // Mode A: Chronicle oracle with staleness guard (matches _modeASwap behavior)
            uint256 updateTs;
            (price, updateTs) = chronicle.readPrice(inst.token);
            if (price == 0 || block.timestamp - updateTs >= STALENESS_GUARD) {
                revert OracleStale(poolId);
            }

            // Dynamic fee: BASE_FEE + riskTier * 10bps
            uint24 fee = uint24(BASE_FEE + (inst.riskTier * 1000));
            feeAmount = (inputAmount * uint256(fee)) / 1_000_000;
        } else {
            // Mode B: cached attested price (updated in _modeBSwap)
            price = lastAttestedPrice[poolId];
            if (price == 0) revert OracleStale(poolId);

            // Mode B fee: 5% on gross output (matches AgentPricing.computeSwap)
            // Computed below after grossOutput is known.
        }

        uint256 grossOutput;
        if (zeroForOne) {
            // token0 (RWA) -> token1 (USDC): output = input * price
            grossOutput = Math.mulDiv(inputAmount, price, 1e18);
        } else {
            // token1 (USDC) -> token0 (RWA): output = input / price
            grossOutput = Math.mulDiv(inputAmount, 1e18, price);
        }

        // Compute fee AFTER grossOutput is known
        if (inst.illiquid) {
            feeAmount = (grossOutput * 500) / 10000;
        }

        outputAmount = grossOutput - feeAmount;
    }

    /// @notice Pool metadata view for Tao indexer (pool discovery)
    /// @dev Used by Tao indexer (substreams package) to catalog pools
    function getPoolMetadata(PoolId poolId) external view returns (IFluxaHook.PoolMetadata memory) {
        if (!_instrumentRegistered[poolId]) revert InstrumentNotRegistered(poolId);

        RWAInstrument storage inst = _instruments[poolId];
        PoolKey storage key = _poolKeys[poolId];

        uint24 fee;
        if (!inst.illiquid) {
            fee = uint24(BASE_FEE + (inst.riskTier * 1000));
        } else {
            fee = 500; // MODE_B_FEE_BPS (uint24)
        }

        return IFluxaHook.PoolMetadata({
            currency0: Currency.unwrap(key.currency0),
            currency1: Currency.unwrap(key.currency1),
            fee: fee,
            tickSpacing: key.tickSpacing,
            state: _poolState[poolId],
            rwaToken: inst.token,
            riskTier: inst.riskTier,
            illiquid: inst.illiquid,
            maturityTs: inst.maturityTs,
            totalLiquidity0: totalLiquidity0[poolId],
            totalLiquidity1: totalLiquidity1[poolId],
            cumulativeYield: cumulativeYield[poolId],
            baseFee: uint256(fee),
            agent: poolAgent[poolId],
            lastAttestedPrice: lastAttestedPrice[poolId],
            lastAttestationTimestamp: lastAttestationTimestamp[poolId]
        });
    }

    receive() external payable {}
}
