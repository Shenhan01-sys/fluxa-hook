// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "./vendor/BaseHook.sol";
import {IFluxaHook} from "./interfaces/IFluxaHook.sol";
import {IChronicleOracle} from "./interfaces/IChronicleOracle.sol";
import {IERC8004Registry, IERC7857Agent} from "./interfaces/IERC8004Registry.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract FluxaHook is BaseHook, IFluxaHook, Ownable, ReentrancyGuardTransient {
    using PoolIdLibrary for PoolKey;
    using Hooks for IHooks;

    uint24  public constant BASE_FEE             = 3000;
    uint256 public constant REPUTATION_THRESHOLD = 50;
    uint256 public constant STALENESS_GUARD      = 1 hours;
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
        emit InstrumentRegistered(poolId, instrument.token, instrument.riskTier, instrument.illiquid, instrument.maturityTs);
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24)
        external
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
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4) {
        PoolId id = key.toId();
        if (_poolState[id] != PoolState.Normal) {
            revert InvalidState(id, _poolState[id], PoolState.Normal);
        }
        if (hookData.length > 0) {
            uint256 agentId = abi.decode(hookData, (uint256));
            agentNft.ownerOf(agentId);
            IERC8004Registry.ReputationSummary memory rep =
                reputationRegistry.getSummary(agentId, address(this), bytes32(0));
            uint256 score = rep.score < 0 ? 0 : uint256(int256(rep.score));
            if (score < REPUTATION_THRESHOLD) revert ReputationTooLow(address(0), score);
            if (poolAgent[id] == address(0)) poolAgent[id] = agentNft.ownerOf(agentId);
        }
        return BaseHook.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4) {
        PoolId id = key.toId();
        if (_poolState[id] == PoolState.Distress) {
            revert InvalidState(id, _poolState[id], PoolState.Normal);
        }
        return BaseHook.beforeRemoveLiquidity.selector;
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
            (, uint256 updateTs) = chronicle.readPrice(inst.token);
            if (block.timestamp - updateTs >= STALENESS_GUARD) revert OracleStale(id);
            uint24 fee = _dynamicFee(inst.riskTier);
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee);
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
                return (BaseHook.beforeSwap.selector, delta, BASE_FEE | OVERRIDE_FEE_FLAG);
            }
        }

        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, BASE_FEE | OVERRIDE_FEE_FLAG);
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

        uint256 hookFee = _computeHookFee(delta);
        if (hookFee > 0) {
            cumulativeYield[id] += hookFee;
            emit HookFee(address(poolManager), id, sender, hookFee);
        }

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

    function _dynamicFee(uint8 riskTier) internal pure returns (uint24) {
        uint24 riskPremium = uint24(riskTier) * 1000;
        uint24 fee = BASE_FEE + riskPremium;
        return fee | OVERRIDE_FEE_FLAG;
    }

    function _computeHookFee(BalanceDelta delta) internal pure returns (uint256) {
        int128 amt0 = delta.amount0();
        if (amt0 < 0) {
            uint256 absAmount = uint256(int256(-amt0));
            return (absAmount * BASE_FEE) / 1e6 / 10;
        }
        return 0;
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
}
