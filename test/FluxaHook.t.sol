// SPDX-License-Identifier: MIT
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

contract FluxaHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    FluxaHook public hook;
    MockChronicleOracle public chronicleOracle;
    MockERC8004 public reputationRegistry;
    MockERC7857 public agentNft;
    MockRWAInstrument public rwaToken;
    PoolId public poolId;

    address public agentUser = makeAddr("agentUser");
    address public bidderUser = makeAddr("bidderUser");
    address public lpUser = makeAddr("lpUser");

    uint256 constant INIT_AMOUNT = 100 ether;

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        chronicleOracle = new MockChronicleOracle();
        reputationRegistry = new MockERC8004();
        agentNft = new MockERC7857();
        rwaToken = new MockRWAInstrument("Goldfinch FIDU", "FIDU", 18);

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
    }

    function _registerInstrument() internal {
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
    }

    function _addInitialLiquidity() internal {
        _registerInstrument();
        IERC20Minimal(Currency.unwrap(currency0)).transfer(lpUser, INIT_AMOUNT);
        IERC20Minimal(Currency.unwrap(currency1)).transfer(lpUser, INIT_AMOUNT);
        vm.startPrank(lpUser);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), INIT_AMOUNT);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), INIT_AMOUNT);
        hook.addLiquidity(key, INIT_AMOUNT, INIT_AMOUNT, lpUser);
        vm.stopPrank();
    }

    function test_deployment_permissions() public view {
        BaseHook.HooksPermissions memory perms = hook.getHookPermissions();
        assertFalse(perms.beforeInitialize);
        assertTrue(perms.afterInitialize);
        assertTrue(perms.beforeAddLiquidity);
        assertTrue(perms.beforeRemoveLiquidity);
        assertTrue(perms.beforeSwap);
        assertTrue(perms.afterSwap);
        assertTrue(perms.beforeSwapReturnDelta);
        assertFalse(perms.afterSwapReturnDelta);
    }

    function test_register_instrument() public {
        _registerInstrument();
        IFluxaHook.RWAInstrument memory stored = hook.viewInstrument(poolId);
        assertEq(stored.token, address(rwaToken));
        assertEq(stored.riskTier, 1);
        assertFalse(stored.illiquid);
        assertEq(uint256(hook.viewPoolState(poolId)), uint256(IFluxaHook.PoolState.Normal));
    }

    function test_addLiquidity_mints_shares() public {
        _addInitialLiquidity();

        FluxaLPShares shares = hook.lpShares(poolId);
        uint256 balance = shares.balanceOf(lpUser);
        uint256 expected = _sqrt(INIT_AMOUNT * INIT_AMOUNT);
        assertEq(balance, expected, "shares balance");
        assertEq(hook.totalLiquidity0(poolId), INIT_AMOUNT, "total liq 0");
        assertEq(hook.totalLiquidity1(poolId), INIT_AMOUNT, "total liq 1");
    }

    function test_addLiquidity_claim_token_balances() public {
        _addInitialLiquidity();

        uint256 token0ClaimID = currency0.toId();
        uint256 token1ClaimID = currency1.toId();

        uint256 token0ClaimsBalance = manager.balanceOf(address(hook), token0ClaimID);
        uint256 token1ClaimsBalance = manager.balanceOf(address(hook), token1ClaimID);

        assertEq(token0ClaimsBalance, INIT_AMOUNT, "t0 claims");
        assertEq(token1ClaimsBalance, INIT_AMOUNT, "t1 claims");
    }

    function test_cannotModifyLiquidity() public {
        _registerInstrument();
        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1 ether, salt: bytes32(0)}),
            ""
        );
    }

    function test_removeLiquidity() public {
        _addInitialLiquidity();

        FluxaLPShares shares = hook.lpShares(poolId);
        uint256 balanceBefore0 = IERC20Minimal(Currency.unwrap(currency0)).balanceOf(lpUser);
        uint256 balanceBefore1 = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(lpUser);
        uint256 burnAmount = shares.balanceOf(lpUser) / 2;

        vm.prank(lpUser);
        (uint256 amount0, uint256 amount1) = hook.removeLiquidity(key, burnAmount);

        assertEq(shares.balanceOf(lpUser), burnAmount, "half shares remain");
        assertEq(IERC20Minimal(Currency.unwrap(currency0)).balanceOf(lpUser) - balanceBefore0, amount0);
        assertEq(IERC20Minimal(Currency.unwrap(currency1)).balanceOf(lpUser) - balanceBefore1, amount1);
    }

    function test_swap_exactInput_zeroForOne() public {
        _addInitialLiquidity();

        IERC20Minimal(Currency.unwrap(currency0)).transfer(address(this), 10 ether);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(swapRouter), 10 ether);

        uint256 balanceOfTokenBBefore = currency1.balanceOfSelf();
        uint256 balanceOfTokenABefore = currency0.balanceOfSelf();

        swap(key, true, -10 ether, "");

        uint256 balanceOfTokenBAfter = currency1.balanceOfSelf();
        uint256 balanceOfTokenAAfter = currency0.balanceOfSelf();

        uint256 expectedOut = 10 ether - (10 ether * 3000 / 1_000_000);
        assertEq(balanceOfTokenBAfter - balanceOfTokenBBefore, expectedOut, "output");
        assertEq(balanceOfTokenABefore - balanceOfTokenAAfter, 10 ether, "input");
    }

    function test_reputation_gate_pass_with_agent() public {
        _registerInstrument();

        uint256 agentId = agentNft.mint(agentUser);
        reputationRegistry.setReputation(agentId, 90);

        IERC20Minimal(Currency.unwrap(currency0)).transfer(agentUser, 1 ether);
        IERC20Minimal(Currency.unwrap(currency1)).transfer(agentUser, 1 ether);
        vm.startPrank(agentUser);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), 1 ether);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), 1 ether);
        hook.addLiquidity(key, 1 ether, 1 ether, agentUser);
        vm.stopPrank();

        FluxaLPShares shares = hook.lpShares(poolId);
        assertGt(shares.balanceOf(agentUser), 0);
    }

    function test_reputation_gate_blocks_low_score() public {
        _registerInstrument();

        uint256 badAgentId = agentNft.mint(agentUser);
        reputationRegistry.setReputation(badAgentId, 30);

        vm.expectRevert();
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1 ether, salt: bytes32(0)}),
            abi.encode(badAgentId)
        );
    }

    function test_auction_commit_reveal_settle() public {
        _addInitialLiquidity();  // hook now holds RWA claims (currency0) + USDC claims (currency1)

        // Trigger distress (oracle reports default)
        chronicleOracle.setDefaulted(address(rwaToken), true);
        hook.setDistress(poolId, IFluxaHook.PoolState.Distress);
        assertEq(uint256(hook.viewPoolState(poolId)), uint256(IFluxaHook.PoolState.Distress));

        // Fund winner with USDC (currency1) and approve hook
        uint256 amount = 1 ether;
        IERC20Minimal(Currency.unwrap(currency1)).transfer(bidderUser, amount);
        vm.prank(bidderUser);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), amount);

        // Commit + reveal + settle
        bytes32 nonce = keccak256("bid1");
        bytes32 commitHash = keccak256(abi.encodePacked(amount, nonce));

        vm.prank(bidderUser);
        hook.commitBid(poolId, commitHash);

        vm.warp(block.timestamp + 1 hours + 1 seconds);

        vm.prank(bidderUser);
        hook.revealBid(poolId, amount, nonce);

        vm.warp(block.timestamp + 30 minutes + 1 seconds);

        // Check winner receives RWA claims (currency0)
        uint256 rwaClaimId = currency0.toId();
        uint256 winnerRWABefore = IERC6909Claims(address(manager)).balanceOf(bidderUser, rwaClaimId);
        uint256 hookRWA = IERC6909Claims(address(manager)).balanceOf(address(hook), rwaClaimId);

        hook.settleAuction(poolId);

        uint256 winnerRWAAfter = IERC6909Claims(address(manager)).balanceOf(bidderUser, rwaClaimId);
        assertEq(winnerRWAAfter - winnerRWABefore, hookRWA, "winner got all RWA claims");
        assertEq(uint256(hook.viewPoolState(poolId)), uint256(IFluxaHook.PoolState.Normal));
    }

    function test_oracle_staleness_blocks_swap() public {
        _addInitialLiquidity();

        chronicleOracle.setPrice(address(rwaToken), 1e18);
        vm.warp(block.timestamp + 2 hours);

        IERC20Minimal(Currency.unwrap(currency0)).transfer(address(this), 1 ether);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(swapRouter), 1 ether);

        vm.expectRevert();
        swap(key, true, -1 ether, "");
    }

    function test_yield_accumulates() public {
        _addInitialLiquidity();

        IERC20Minimal(Currency.unwrap(currency0)).transfer(address(this), 10 ether);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(swapRouter), 10 ether);

        swap(key, true, -10 ether, "");

        uint256 yield0 = hook.cumulativeYield(poolId);
        uint256 expectedYield = (10 ether * 3000) / 1_000_000;
        assertEq(yield0, expectedYield, "yield tracks fees");
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
