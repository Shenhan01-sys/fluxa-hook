// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IERC6909Claims} from "@uniswap/v4-core/src/interfaces/external/IERC6909Claims.sol";

import {FluxaHook} from "../src/FluxaHook.sol";
import {FluxaLPShares} from "../src/FluxaLPShares.sol";
import {BaseHook} from "../src/vendor/BaseHook.sol";
import {IFluxaHook} from "../src/interfaces/IFluxaHook.sol";
import {MockChronicleOracle} from "../src/mocks/MockChronicleOracle.sol";
import {MockERC8004, MockERC7857} from "../src/mocks/MockERC8004.sol";
import {MockRWAInstrument} from "../src/mocks/MockRWAInstrument.sol";

contract ModeCTests is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    FluxaHook public hook;
    MockChronicleOracle public chronicleOracle;
    MockERC8004 public reputationRegistry;
    MockERC7857 public agentNft;
    MockRWAInstrument public rwaToken;
    PoolId public poolId;

    address public bidder1 = makeAddr("bidder1");
    address public bidder2 = makeAddr("bidder2");
    address public bidder3 = makeAddr("bidder3");

    uint256 constant INIT_AMOUNT = 100 ether;
    uint256 constant MODE_C_FEE_BPS = 200; // 2% auction fee

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        chronicleOracle = new MockChronicleOracle();
        reputationRegistry = new MockERC8004();
        agentNft = new MockERC7857();
        rwaToken = new MockRWAInstrument("Illiquid RWA", "IRWA", 18);

        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG |
            Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        (address hookAddr, bytes32 salt) = HookMiner.find(
            address(this),
            flags,
            type(FluxaHook).creationCode,
            abi.encode(manager, address(chronicleOracle), address(reputationRegistry), address(agentNft), address(this))
        );

        hook = new FluxaHook{salt: salt}(
            manager,
            chronicleOracle,
            reputationRegistry,
            agentNft,
            address(this)
        );
        require(address(hook) == hookAddr, "HookMiner: address mismatch");

        _registerAndFund();
    }

    function _registerAndFund() internal {
        // Register instrument
        rwaToken.mint(address(this), 100 ether);
        chronicleOracle.setPrice(address(rwaToken), 1e18);
        chronicleOracle.setYield(address(rwaToken), 1000);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0,
            tickSpacing: 60,
            hooks: hook
        });
        poolId = key.toId();

        IFluxaHook.RWAInstrument memory inst = IFluxaHook.RWAInstrument({
            token: address(rwaToken),
            riskTier: 1,
            oracle: address(chronicleOracle),
            illiquid: false,
            maturityTs: block.timestamp + 365 days
        });
        hook.registerInstrument(poolId, inst, key);
        manager.initialize(key, 79228162514264337593543950336);

        // Add initial liquidity (hook gets ERC6909 claims for both currencies)
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), INIT_AMOUNT);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), INIT_AMOUNT);
        hook.addLiquidity(key, INIT_AMOUNT, INIT_AMOUNT, address(this));
    }

    function _settleAuctionScenario(address winner, uint256 amount) internal {
        // Fund winner with USDC (currency1) and approve
        vm.prank(address(this));
        IERC20Minimal(Currency.unwrap(currency1)).transfer(winner, amount);

        vm.startPrank(winner);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), amount);

        // Commit + reveal + settle
        bytes32 nonce = keccak256(abi.encodePacked("nonce", winner, amount));
        bytes32 commitHash = keccak256(abi.encodePacked(amount, nonce));
        hook.commitBid(poolId, commitHash);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours + 1 seconds);

        vm.prank(winner);
        hook.revealBid(poolId, amount, nonce);

        vm.warp(block.timestamp + 30 minutes + 1 seconds);
        hook.settleAuction(poolId);
    }

    // ==========================================================================
    // HAPPY PATH TESTS
    // ==========================================================================

    function test_modeC_happy_path_full_settlement() public {
        // Trigger distress
        chronicleOracle.setDefaulted(address(rwaToken), true);
        hook.setDistress(poolId, IFluxaHook.PoolState.Distress);

        // Fund winner with USDC (currency1) BEFORE snapshot
        uint256 bidAmount = 5 ether;
        vm.prank(address(this));
        IERC20Minimal(Currency.unwrap(currency1)).transfer(bidder1, bidAmount);

        uint256 winnerUSDCBefore = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(bidder1);
        uint256 usdcClaimId = currency1.toId();
        uint256 hookUSDCClaimsBefore = IERC6909Claims(address(manager)).balanceOf(address(hook), usdcClaimId);

        // Commit + reveal + settle
        vm.startPrank(bidder1);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), bidAmount);
        bytes32 nonce = keccak256("happy_path");
        bytes32 commitHash = keccak256(abi.encodePacked(bidAmount, nonce));
        hook.commitBid(poolId, commitHash);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours + 1 seconds);
        vm.prank(bidder1);
        hook.revealBid(poolId, bidAmount, nonce);
        vm.warp(block.timestamp + 30 minutes + 1 seconds);
        hook.settleAuction(poolId);

        // Assertions
        uint256 winnerUSDCAfter = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(bidder1);
        uint256 hookUSDCClaimsAfter = IERC6909Claims(address(manager)).balanceOf(address(hook), usdcClaimId);

        assertEq(winnerUSDCBefore - winnerUSDCAfter, bidAmount, "winner paid USDC");
        assertEq(hookUSDCClaimsAfter - hookUSDCClaimsBefore, bidAmount, "hook gained USDC claims");
        assertEq(uint256(hook.viewPoolState(poolId)), uint256(IFluxaHook.PoolState.Normal), "pool state back to Normal");
    }

    function test_modeC_winner_gets_RWA_claims() public {
        chronicleOracle.setDefaulted(address(rwaToken), true);
        hook.setDistress(poolId, IFluxaHook.PoolState.Distress);

        uint256 rwaClaimId = currency0.toId();
        uint256 hookRWA = IERC6909Claims(address(manager)).balanceOf(address(hook), rwaClaimId);
        uint256 winnerRWABefore = IERC6909Claims(address(manager)).balanceOf(bidder1, rwaClaimId);
        assertGt(hookRWA, 0, "hook holds RWA claims");

        _settleAuctionScenario(bidder1, 5 ether);

        uint256 winnerRWAAfter = IERC6909Claims(address(manager)).balanceOf(bidder1, rwaClaimId);
        uint256 hookRWAAfter = IERC6909Claims(address(manager)).balanceOf(address(hook), rwaClaimId);

        assertEq(winnerRWAAfter - winnerRWABefore, hookRWA, "winner got all RWA claims");
        assertEq(hookRWAAfter, 0, "hook lost all RWA claims");
    }

    function test_modeC_auction_fee_tracks_correctly() public {
        chronicleOracle.setDefaulted(address(rwaToken), true);
        hook.setDistress(poolId, IFluxaHook.PoolState.Distress);

        uint256 bidAmount = 10 ether;
        uint256 expectedFee = (bidAmount * MODE_C_FEE_BPS) / 10000;

        _settleAuctionScenario(bidder1, bidAmount);

        uint256 yieldAcc = hook.cumulativeYield(poolId);
        assertEq(yieldAcc, expectedFee, "2% fee tracked in cumulativeYield");
        assertEq(yieldAcc, 0.2 ether, "2% of 10 ether = 0.2 ether");
    }

    function test_modeC_event_emission() public {
        chronicleOracle.setDefaulted(address(rwaToken), true);
        hook.setDistress(poolId, IFluxaHook.PoolState.Distress);

        uint256 amount = 5 ether;

        // fund winner
        vm.prank(address(this));
        IERC20Minimal(Currency.unwrap(currency1)).transfer(bidder1, amount);

        vm.startPrank(bidder1);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), amount);

        bytes32 nonce = keccak256("event_test");
        bytes32 commitHash = keccak256(abi.encodePacked(amount, nonce));
        hook.commitBid(poolId, commitHash);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours + 1 seconds);

        vm.prank(bidder1);
        hook.revealBid(poolId, amount, nonce);

        vm.warp(block.timestamp + 30 minutes + 1 seconds);

        // Expect AuctionSettled event
        uint256 expectedFee = (amount * MODE_C_FEE_BPS) / 10000;
        vm.expectEmit(true, false, false, true);
        emit IFluxaHook.AuctionSettled(poolId, bidder1, amount, expectedFee, amount - expectedFee);

        hook.settleAuction(poolId);
    }

    // ==========================================================================
    // STATE ENFORCEMENT
    // ==========================================================================

    function test_modeC_cannot_commit_when_not_distress() public {
        // Pool is in Normal state
        assertEq(uint256(hook.viewPoolState(poolId)), uint256(IFluxaHook.PoolState.Normal));

        bytes32 commitHash = keccak256(abi.encodePacked(uint256(1 ether), bytes32("test")));

        vm.prank(bidder1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IFluxaHook.InvalidState.selector,
                poolId,
                IFluxaHook.PoolState.Normal,
                IFluxaHook.PoolState.Distress
            )
        );
        hook.commitBid(poolId, commitHash);
    }

    function test_modeC_cannot_reveal_before_commit_deadline() public {
        chronicleOracle.setDefaulted(address(rwaToken), true);
        hook.setDistress(poolId, IFluxaHook.PoolState.Distress);

        uint256 amount = 5 ether;
        bytes32 nonce = keccak256("premature");
        bytes32 commitHash = keccak256(abi.encodePacked(amount, nonce));

        vm.prank(bidder1);
        hook.commitBid(poolId, commitHash);

        vm.prank(bidder1);
        vm.expectRevert("CommitPhase");
        hook.revealBid(poolId, amount, nonce);
    }

    function test_modeC_cannot_settle_before_reveal_deadline() public {
        chronicleOracle.setDefaulted(address(rwaToken), true);
        hook.setDistress(poolId, IFluxaHook.PoolState.Distress);

        uint256 amount = 5 ether;

        vm.prank(address(this));
        IERC20Minimal(Currency.unwrap(currency1)).transfer(bidder1, amount);
        vm.startPrank(bidder1);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), amount);

        bytes32 nonce = keccak256("early_settle");
        bytes32 commitHash = keccak256(abi.encodePacked(amount, nonce));
        hook.commitBid(poolId, commitHash);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 hours + 1 seconds);

        vm.prank(bidder1);
        hook.revealBid(poolId, amount, nonce);

        // Try to settle before reveal deadline elapses
        vm.expectRevert("RevealPhase");
        hook.settleAuction(poolId);
    }

    function test_modeC_no_valid_revealed_bids_reverts() public {
        chronicleOracle.setDefaulted(address(rwaToken), true);
        hook.setDistress(poolId, IFluxaHook.PoolState.Distress);

        // Commit a bid but NEVER reveal it
        uint256 amount = 5 ether;
        bytes32 commitHash = keccak256("hidden_bid");
        vm.prank(bidder1);
        hook.commitBid(poolId, commitHash);

        // Wait past reveal deadline
        vm.warp(block.timestamp + 2 hours);

        // Try to settle — auction is active but no revealed bids → NoValidBids
        vm.expectRevert(
            abi.encodeWithSelector(IFluxaHook.NoValidBids.selector, poolId)
        );
        hook.settleAuction(poolId);
    }

    function test_modeC_no_auction_started_reverts() public {
        chronicleOracle.setDefaulted(address(rwaToken), true);
        hook.setDistress(poolId, IFluxaHook.PoolState.Distress);

        // Wait, no bids committed at all
        vm.warp(block.timestamp + 2 hours);

        // Auction was never activated
        vm.expectRevert(
            abi.encodeWithSelector(IFluxaHook.AuctionNotActive.selector, poolId)
        );
        hook.settleAuction(poolId);
    }

    function test_modeC_inactive_auction_reverts() public {
        // No auction started, no distress triggered
        vm.expectRevert(
            abi.encodeWithSelector(IFluxaHook.AuctionNotActive.selector, poolId)
        );
        hook.settleAuction(poolId);
    }

    // ==========================================================================
    // MULTIPLE BIDDERS
    // ==========================================================================

    function test_modeC_highest_bidder_wins() public {
        chronicleOracle.setDefaulted(address(rwaToken), true);
        hook.setDistress(poolId, IFluxaHook.PoolState.Distress);

        // bidders commit with different amounts
        uint256 bid1 = 3 ether;
        uint256 bid2 = 7 ether; // highest
        uint256 bid3 = 5 ether;

        // Fund all bidders
        IERC20Minimal(Currency.unwrap(currency1)).transfer(bidder1, bid1);
        IERC20Minimal(Currency.unwrap(currency1)).transfer(bidder2, bid2);
        IERC20Minimal(Currency.unwrap(currency1)).transfer(bidder3, bid3);

        bytes32 nonce1 = keccak256("n1"); bytes32 nonce2 = keccak256("n2"); bytes32 nonce3 = keccak256("n3");
        bytes32 commit1 = keccak256(abi.encodePacked(bid1, nonce1));
        bytes32 commit2 = keccak256(abi.encodePacked(bid2, nonce2));
        bytes32 commit3 = keccak256(abi.encodePacked(bid3, nonce3));

        vm.prank(bidder1); hook.commitBid(poolId, commit1);
        vm.prank(bidder2); hook.commitBid(poolId, commit2);
        vm.prank(bidder3); hook.commitBid(poolId, commit3);

        vm.warp(block.timestamp + 1 hours + 1 seconds);

        vm.prank(bidder1); IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), bid1);
        vm.prank(bidder2); IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), bid2);
        vm.prank(bidder3); IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), bid3);

        vm.prank(bidder1); hook.revealBid(poolId, bid1, nonce1);
        vm.prank(bidder3); hook.revealBid(poolId, bid3, nonce3);
        vm.prank(bidder2); hook.revealBid(poolId, bid2, nonce2);

        vm.warp(block.timestamp + 30 minutes + 1 seconds);

        // Snapshot before settlement
        uint256 bidder1USDC = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(bidder1);
        uint256 bidder2USDC = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(bidder2);
        uint256 bidder3USDC = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(bidder3);

        hook.settleAuction(poolId);

        // Only bidder2 (highest) should have paid
        uint256 bidder1USDCAfter = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(bidder1);
        uint256 bidder2USDCAfter = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(bidder2);
        uint256 bidder3USDCAfter = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(bidder3);

        assertEq(bidder1USDCAfter, bidder1USDC, "bidder1 not paid");
        assertEq(bidder3USDCAfter, bidder3USDC, "bidder3 not paid");
        assertEq(bidder2USDC - bidder2USDCAfter, bid2, "bidder2 paid highest bid");
    }

    function test_modeC_multiple_settles_reverts_second_attempt() public {
        chronicleOracle.setDefaulted(address(rwaToken), true);
        hook.setDistress(poolId, IFluxaHook.PoolState.Distress);

        _settleAuctionScenario(bidder1, 5 ether);

        // Second settle attempt should revert (auction deleted)
        vm.expectRevert(
            abi.encodeWithSelector(IFluxaHook.AuctionNotActive.selector, poolId)
        );
        hook.settleAuction(poolId);
    }

    // ==========================================================================
    // LP APPRECIATION
    // ==========================================================================

    function test_modeC_lp_shares_appreciate_after_settlement() public {
        chronicleOracle.setDefaulted(address(rwaToken), true);
        hook.setDistress(poolId, IFluxaHook.PoolState.Distress);

        uint256 bidAmount = 10 ether;
        uint256 expectedFee = (bidAmount * MODE_C_FEE_BPS) / 10000;

        _settleAuctionScenario(bidder1, bidAmount);

        // Verify LP value via claim token balance
        uint256 usdcClaimId = currency1.toId();
        uint256 hookUSDCClaims = IERC6909Claims(address(manager)).balanceOf(address(hook), usdcClaimId);

        // Initial hook had 100 USDC claims, should now have 100 + 10 - fee? No actually...
        // Let me re-read: USDC bid is SETTLED to PM and hook gets NEW claims for full bidAmount
        // So hook's USDC claims = 100 (initial) + 10 (bid) = 110
        assertEq(hookUSDCClaims, INIT_AMOUNT + bidAmount, "hook has initial + bid claims");

        // LP share total supply stays same (100 ether), but backing value increased
        uint256 totalSupply = hook.lpShares(poolId).totalSupply();
        assertEq(totalSupply, 100 ether, "same total LP shares");

        // cumulativeYield tracks fee (2% of 10 = 0.2 ether)
        uint256 yieldAcc = hook.cumulativeYield(poolId);
        assertEq(yieldAcc, expectedFee, "fee recorded in yield");
    }
}
