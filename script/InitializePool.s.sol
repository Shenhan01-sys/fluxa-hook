// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Hooks, IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {FluxaHook} from "../src/FluxaHook.sol";
import {IFluxaHook} from "../src/interfaces/IFluxaHook.sol";
import {MockChronicleOracle} from "../src/mocks/MockChronicleOracle.sol";
import {MockRWAInstrument} from "../src/mocks/MockRWAInstrument.sol";

contract InitializePool is Script {
    address constant BASE_SEPOLIA_POOL_MANAGER = 0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408;

    // v5 deployed addresses (correct PoolManager)
    address constant FLUXA_HOOK    = 0x98aBecc8db108969028b01E709Eb8126661bdac8;
    address constant CHRONICLE      = 0x40F0676F5C470CE425706F0FA45c7b768a0D2D94;
    address constant RWA_TOKEN      = 0xA92FB17c8AC46bEfa63d0b3951EA5a5Edd81FCC7;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);

        vm.startBroadcast(deployerPk);

        // 1. Deploy a mock USDC (18 decimals for simplicity — matches hook's 1e18 scale)
        MockRWAInstrument usdc = new MockRWAInstrument("Fluxa Test USDC", "fUSDC", 18);
        console2.log("MockUSDC deployed:", address(usdc));

        // 2. Mint tokens to deployer
        uint256 mintAmount = 1_000_000 * 1e18; // 1M each
        usdc.mint(deployer, mintAmount);
        MockRWAInstrument(RWA_TOKEN).mint(deployer, mintAmount);
        console2.log("Minted 1M fUSDC + 1M FRWA to deployer");

        // 3. Set Chronicle oracle price for RWA token (1 RWA = 1 USDC)
        MockChronicleOracle chronicle = MockChronicleOracle(CHRONICLE);
        chronicle.setPrice(RWA_TOKEN, 1e18);
        chronicle.setYield(RWA_TOKEN, 1000); // 10% APY in bps
        console2.log("Chronicle oracle price set: 1 RWA = 1 USDC, yield 10% APY");

        // 4. Build PoolKey — currency0 < currency1 (sorted by address)
        Currency currency0;
        Currency currency1;
        if (address(usdc) < RWA_TOKEN) {
            currency0 = Currency.wrap(address(usdc));
            currency1 = Currency.wrap(RWA_TOKEN);
        } else {
            currency0 = Currency.wrap(RWA_TOKEN);
            currency1 = Currency.wrap(address(usdc));
        }

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(payable(FLUXA_HOOK))
        });

        PoolId poolId = PoolIdLibrary.toId(key);
        console2.log("PoolKey built");
        console2.log("  currency0:", Currency.unwrap(currency0));
        console2.log("  currency1:", Currency.unwrap(currency1));
        console2.log("  poolId:", vm.toString(PoolId.unwrap(poolId)));

        // 5. Register instrument on FluxaHook (onlyOwner)
        FluxaHook hook = FluxaHook(payable(FLUXA_HOOK));
        IFluxaHook.RWAInstrument memory inst = IFluxaHook.RWAInstrument({
            token: RWA_TOKEN,
            riskTier: 1,
            oracle: CHRONICLE,
            illiquid: false,
            maturityTs: block.timestamp + 365 days
        });
        hook.registerInstrument(poolId, inst, key);
        console2.log("Instrument registered on hook");

        // 6. Initialize pool on PoolManager
        IPoolManager(BASE_SEPOLIA_POOL_MANAGER).initialize(key, SQRT_PRICE_1_1);
        console2.log("Pool initialized on PoolManager");

        // 7. Approve hook to spend tokens for addLiquidity
        uint256 liqAmount = 100_000 * 1e18; // 100K each
        IERC20(Currency.unwrap(currency0)).approve(FLUXA_HOOK, liqAmount);
        IERC20(Currency.unwrap(currency1)).approve(FLUXA_HOOK, liqAmount);
        console2.log("Approved hook to spend 100K of each token");

        // 8. Add initial liquidity
        hook.addLiquidity(key, liqAmount, liqAmount, deployer);
        console2.log("Initial liquidity added: 100K fUSDC + 100K FRWA");

        vm.stopBroadcast();

        // Print summary
        console2.log("\n=== Pool Initialization Summary ===");
        console2.log("MockUSDC:", address(usdc));
        console2.log("RWA Token:", RWA_TOKEN);
        console2.log("PoolId:", vm.toString(PoolId.unwrap(poolId)));
        console2.log("Liquidity: 100K fUSDC + 100K FRWA");
        console2.log("Price: 1:1 (sqrtPriceX96 = 2^96)");
        console2.log("Yield: 10% APY (1000 bps)");
        console2.log("Maturity:", block.timestamp + 365 days);
        console2.log("\n=== FE Pool URL ===");
        console2.log("http://localhost:3000/pool/%s", vm.toString(PoolId.unwrap(poolId)));
    }
}
