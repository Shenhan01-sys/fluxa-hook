// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {HookMiner} from "@uniswap/v4-periphery/test/shared/HookMiner.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {IERC6909Claims} from "@uniswap/v4-core/src/interfaces/external/IERC6909Claims.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {FluxaHook} from "../src/FluxaHook.sol";
import {FluxaLPShares} from "../src/FluxaLPShares.sol";
import {BaseHook} from "../src/vendor/BaseHook.sol";
import {IFluxaHook} from "../src/interfaces/IFluxaHook.sol";
import {MockChronicleOracle} from "../src/mocks/MockChronicleOracle.sol";
import {MockERC8004, MockERC7857} from "../src/mocks/MockERC8004.sol";
import {MockRWAInstrument} from "../src/mocks/MockRWAInstrument.sol";

/// @title TaoTests - test deterministic quote + metadata view functions
/// @dev Quote function is the Solidity-side of Tao self-integration.
/// Tao (Rust library, ~20% CoW Swap mainnet + ~40% CoW Base) calls these
/// view functions via substreams indexing to discover + price liquidity.
/// Reference: Incubator-Maps/T08 - How to Win Orderflow
contract TaoTests is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    FluxaHook public hook;
    MockChronicleOracle public chronicleOracle;
    MockERC8004 public reputationRegistry;
    MockERC7857 public agentNft;
    MockRWAInstrument public rwaToken;
    PoolId public poolId;
    PoolId public illiquidPoolId;
    PoolKey public illiquidKey;

    address public bidder1 = makeAddr("bidder1");

    uint256 constant INIT_AMOUNT = 100 ether;
    uint256 constant AI_PRICE = 1.5e18; // 1 token0 = 1.5 token1
    uint256 constant BASE_FEE = 3000; // 0.3%
    uint256 constant MODE_B_FEE_BPS = 500; // 5%

    function setUp() public {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        chronicleOracle = new MockChronicleOracle();
        reputationRegistry = new MockERC8004();
        agentNft = new MockERC7857();
        rwaToken = new MockRWAInstrument("Liquid RWA", "LRWA", 18);

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

        _registerLiquidPool();
    }

    function _registerLiquidPool() internal {
        rwaToken.mint(address(this), 100 ether);
        chronicleOracle.setPrice(address(rwaToken), 1e18); // 1:1 oracle
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
            riskTier: 1, // riskTier=1 → dynamic fee 0.3% + 1*0.1% = 0.4%
            oracle: address(chronicleOracle),
            illiquid: false,
            maturityTs: block.timestamp + 365 days
        });
        hook.registerInstrument(poolId, inst, key);
        manager.initialize(key, 79228162514264337593543950336);

        // Add initial liquidity (hook holds ERC6909 claims)
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), INIT_AMOUNT);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), INIT_AMOUNT);
        hook.addLiquidity(key, INIT_AMOUNT, INIT_AMOUNT, address(this));
    }

    function _registerIlliquidPool() internal {
        MockRWAInstrument illiquidRWA = new MockRWAInstrument("Illiquid RWA", "IRWA", 18);
        illiquidRWA.mint(address(this), INIT_AMOUNT * 2);  // fund extra for test swaps

        // Use tickSpacing=120 to avoid PoolAlreadyInitialized (different PoolKey)
        PoolKey memory _illiquidKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0,
            tickSpacing: 120,
            hooks: hook
        });
        illiquidKey = _illiquidKey;
        illiquidPoolId = _illiquidKey.toId();

        IFluxaHook.RWAInstrument memory inst = IFluxaHook.RWAInstrument({
            token: address(illiquidRWA),
            riskTier: 1,
            oracle: address(chronicleOracle),
            illiquid: true, // Mode B
            maturityTs: block.timestamp + 365 days
        });
        hook.registerInstrument(illiquidPoolId, inst, _illiquidKey);
        manager.initialize(_illiquidKey, 79228162514264337593543950336);

        IERC20Minimal(Currency.unwrap(currency0)).approve(address(hook), INIT_AMOUNT);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(hook), INIT_AMOUNT);
        hook.addLiquidity(_illiquidKey, INIT_AMOUNT, INIT_AMOUNT, address(this));

        // Also approve swapRouter for Mode B swap tests
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(swapRouter), INIT_AMOUNT);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(swapRouter), INIT_AMOUNT);
    }

    // ==========================================================================
    // MODE A QUOTE TESTS (liquid RWA)
    // ==========================================================================

    function test_tao_quote_modeA_zeroForOne() public {
        // Mode A: 1:1 oracle price, riskTier=1 (fee = 0.3% + 0.1% = 0.4%)
        uint256 input = 10 ether;
        (uint256 output, uint256 fee) = hook.quote(poolId, input, true);

        // fee = 10 * 4000 / 1_000_000 = 0.04 ether
        uint256 expectedFee = (input * 4000) / 1_000_000;
        // grossOutput = 10 * 1e18 / 1e18 = 10 ether
        uint256 expectedGross = Math.mulDiv(input, 1e18, 1e18);
        uint256 expectedOutput = expectedGross - expectedFee;

        assertEq(fee, expectedFee, "Mode A fee matches formula (BASE_FEE + riskTier*1000)");
        assertEq(output, expectedOutput, "Mode A output = gross - fee");
    }

    function test_tao_quote_modeA_oneForZero() public {
        uint256 input = 10 ether;
        (uint256 output, uint256 fee) = hook.quote(poolId, input, false);

        // At 1:1 oracle, output == input (before fee)
        uint256 expectedFee = (input * 4000) / 1_000_000;
        uint256 expectedOutput = input - expectedFee;

        assertEq(fee, expectedFee, "Mode A fee (oneForZero)");
        assertEq(output, expectedOutput, "Mode A output (oneForZero)");
    }

    function test_tao_quote_modeA_riskTier_impacts_fee() public {
        // Quote with current riskTier=1 (0.4%), fee = 10e * 4000/1e6 = 0.04 ether
        uint256 input = 10 ether;
        (, uint256 feeCurrent) = hook.quote(poolId, input, true);
        assertEq(feeCurrent, 0.04 ether, "riskTier=1 => 0.4% fee");
    }

    function test_tao_quote_modeA_stale_oracle_reverts() public {
        // Make oracle stale (older than 1 hour)
        chronicleOracle.setPrice(address(rwaToken), 1e18);
        vm.warp(block.timestamp + 2 hours);

        vm.expectRevert(abi.encodeWithSelector(IFluxaHook.OracleStale.selector, poolId));
        hook.quote(poolId, 10 ether, true);
    }

    function test_tao_quote_modeA_not_registered_reverts() public {
        PoolId fakePool = PoolId.wrap(bytes32(uint256(0x1234)));
        vm.expectRevert(abi.encodeWithSelector(IFluxaHook.InstrumentNotRegistered.selector, fakePool));
        hook.quote(fakePool, 10 ether, true);
    }

    function test_tao_quote_modeA_distress_reverts() public {
        chronicleOracle.setDefaulted(address(rwaToken), true);
        hook.setDistress(poolId, IFluxaHook.PoolState.Distress);

        vm.expectRevert(
            abi.encodeWithSelector(
                IFluxaHook.InvalidState.selector,
                poolId, IFluxaHook.PoolState.Distress, IFluxaHook.PoolState.Normal
            )
        );
        hook.quote(poolId, 10 ether, true);
    }

    // ==========================================================================
    // MODE B QUOTE TESTS (illiquid RWA, cached attested price)
    // ==========================================================================

    function test_tao_quote_modeB_no_cached_price_reverts() public {
        _registerIlliquidPool();

        // No swap yet, so no cached price
        vm.expectRevert(abi.encodeWithSelector(IFluxaHook.OracleStale.selector, illiquidPoolId));
        hook.quote(illiquidPoolId, 10 ether, true);
    }

    function test_tao_quote_modeB_after_swap_uses_cached_price() public {
        _registerIlliquidPool();

        // Perform a Mode B swap to cache the AI price
        bytes memory proof = abi.encode(bytes32("test_proof"));
        chronicleOracle.setAttestation(keccak256(proof), AI_PRICE); // 1:1.5
        bytes memory hookData = abi.encode(proof);

        // Swap to cache price
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(swapRouter), 10 ether);
        swap(illiquidKey, true, -int256(10 ether), hookData);

        // Verify price cached
        assertEq(hook.lastAttestedPrice(illiquidPoolId), AI_PRICE, "price cached");

        // Quote should now use cached price (1:1.5)
        uint256 input = 10 ether;
        (uint256 output, uint256 fee) = hook.quote(illiquidPoolId, input, true);

        // Fee: 5% = 0.5 ether on 15 ether gross
        uint256 expectedGross = Math.mulDiv(input, AI_PRICE, 1e18); // 15 ether
        uint256 expectedFee = (expectedGross * 500) / 10000; // 0.75 ether
        uint256 expectedOutput = expectedGross - expectedFee; // 14.25 ether

        assertEq(fee, expectedFee, "Mode B fee 5%");
        assertEq(output, expectedOutput, "Mode B output with cached price");
    }

    // ==========================================================================
    // POOL METADATA TESTS
    // ==========================================================================

    function test_tao_getPoolMetadata_liquid() public {
        IFluxaHook.PoolMetadata memory meta = hook.getPoolMetadata(poolId);

        assertEq(meta.currency0, Currency.unwrap(currency0), "currency0");
        assertEq(meta.currency1, Currency.unwrap(currency1), "currency1");
        assertEq(meta.fee, 4000, "fee (BASE_FEE + riskTier*1000)");
        assertEq(meta.tickSpacing, int24(60), "tickSpacing");
        assertEq(uint256(meta.state), uint256(IFluxaHook.PoolState.Normal), "state Normal");
        assertEq(meta.rwaToken, address(rwaToken), "rwaToken");
        assertEq(meta.riskTier, 1, "riskTier");
        assertFalse(meta.illiquid, "illiquid = false for Mode A");
        assertEq(meta.totalLiquidity0, INIT_AMOUNT, "totalLiquidity0");
        assertEq(meta.totalLiquidity1, INIT_AMOUNT, "totalLiquidity1");
        assertEq(meta.cumulativeYield, 0, "cumulativeYield initial");
        assertEq(meta.baseFee, 4000, "baseFee");
        assertEq(meta.lastAttestedPrice, 0, "no attest price for Mode A");
    }

    function test_tao_getPoolMetadata_illiquid() public {
        _registerIlliquidPool();

        IFluxaHook.PoolMetadata memory meta = hook.getPoolMetadata(illiquidPoolId);

        assertTrue(meta.illiquid, "illiquid = true for Mode B pool");
        assertEq(meta.fee, 500, "Mode B fee = 500 bps (5%)");
        assertEq(meta.baseFee, 500, "Mode B baseFee");
    }

    function test_tao_getPoolMetadata_not_registered_reverts() public {
        PoolId fakePool = PoolId.wrap(bytes32(uint256(0x1234)));
        vm.expectRevert(abi.encodeWithSelector(IFluxaHook.InstrumentNotRegistered.selector, fakePool));
        hook.getPoolMetadata(fakePool);
    }

    function test_tao_getPoolMetadata_distress_state() public {
        chronicleOracle.setDefaulted(address(rwaToken), true);
        hook.setDistress(poolId, IFluxaHook.PoolState.Distress);

        IFluxaHook.PoolMetadata memory meta = hook.getPoolMetadata(poolId);
        assertEq(uint256(meta.state), uint256(IFluxaHook.PoolState.Distress), "state Distress");
    }

    // ==========================================================================
    // TAO INTEGRATION SEMANTICS
    // ==========================================================================

    function test_tao_quote_is_deterministic() public {
        // Deterministic: same input, same output (no timestamp, no block.number, no random state)
        uint256 input = 7 ether;
        (uint256 output1, uint256 fee1) = hook.quote(poolId, input, true);

        // Move forward in time (oracle still fresh due to no staleness)
        vm.warp(block.timestamp + 30 minutes);

        (uint256 output2, uint256 fee2) = hook.quote(poolId, input, true);

        assertEq(output1, output2, "deterministic output across time");
        assertEq(fee1, fee2, "deterministic fee across time");
    }

    function test_tao_quote_consistent_with_swap() public {
        // Quote before swap should match actual swap outcome (within 1 wei rounding)
        uint256 input = 10 ether;
        (uint256 quotedOutput, ) = hook.quote(poolId, input, true);

        IERC20Minimal(Currency.unwrap(currency0)).approve(address(swapRouter), input);

        uint256 balanceBefore = currency1.balanceOfSelf();
        swap(key, true, -int256(input), "");
        uint256 balanceAfter = currency1.balanceOfSelf();

        uint256 actualOutput = balanceAfter - balanceBefore;

        // Allow 1 wei rounding error
        assertEq(quotedOutput, actualOutput, "quote predicts swap output");
    }
}
