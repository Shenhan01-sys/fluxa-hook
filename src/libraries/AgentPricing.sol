// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title AgentPricing Library
/// @notice Transform AI-inferred price (uint256, 18 decimals) to BeforeSwapDelta
/// @dev Mode B: illiquid RWA pricing. Vault ref: 06-return-delta-hooks/index.md:466-564
///      Supports ONLY exact input (amountSpecified < 0). For exact output, FluxaHook
///      should fall back to Mode A path.
library AgentPricing {
    using CurrencySettler for Currency;

    /// @notice Mode B fee: 5% (500 bps) for illiquid RWA risk premium
    uint256 constant MODE_B_FEE_BPS = 500;
    uint256 constant BPS_DENOMINATOR = 10000;
    uint256 constant PRICE_DECIMALS = 1e18;

    struct SwapResult {
        BeforeSwapDelta delta;
        uint256 feeAmount;
        uint256 grossOutput;
        uint256 netOutput;
    }

    error InvalidPrice(uint256 price);
    error ExactOutputNotSupported();
    error Overflow();

    /// @notice Compute the BeforeSwapDelta for Mode B swap (exact input only)
    /// @param params Swap params with amountSpecified (must be < 0 = exact input)
    /// @param key Pool key for currency resolution
    /// @param aiPrice AI-inferred price (token1 per token0) in 18-dec format
    /// @param poolManager Pool Manager for settle/take operations
    /// @return result SwapResult with delta, fee, gross/net output
    function computeSwap(
        SwapParams calldata params,
        PoolKey calldata key,
        uint256 aiPrice,
        IPoolManager poolManager
    ) external returns (SwapResult memory result) {
        if (aiPrice == 0) revert InvalidPrice(aiPrice);
        if (params.amountSpecified >= 0) revert ExactOutputNotSupported();

        uint256 inputAmount = uint256(-params.amountSpecified);

        // Compute gross output at AI-inferred price
        if (params.zeroForOne) {
            // token0 → token1: output = input * price
            result.grossOutput = Math.mulDiv(inputAmount, aiPrice, PRICE_DECIMALS);
        } else {
            // token1 → token0: output = input / price
            result.grossOutput = Math.mulDiv(inputAmount, PRICE_DECIMALS, aiPrice);
        }

        // Fee (5%) deducted from gross output
        result.feeAmount = Math.mulDiv(result.grossOutput, MODE_B_FEE_BPS, BPS_DENOMINATOR);
        result.netOutput = result.grossOutput - result.feeAmount;

        // Build BeforeSwapDelta
        // Vault ref: 06-return-delta-hooks/index.md:503-525
        // Exact input (specAmt < 0):
        //   deltaSpecified = +inputAmt  (hook takes input from PM)
        //   deltaUnspecified = -netOut (hook gives net output to PM)
        // Constraint (from v4-core Hooks.sol):
        //   For exact input: deltaSpecified <= -specAmt = inputAmt ✓ (equality)
        if (inputAmount > uint256(uint128(type(int128).max))) revert Overflow();
        if (result.netOutput > uint256(uint128(type(int128).max))) revert Overflow();

        result.delta = toBeforeSwapDelta(
            int128(int256(inputAmount)),
            -int128(int256(result.netOutput))
        );

        // Execute swap via ERC-6909 claims (CSMM pattern)
        Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        Currency outputCurrency = params.zeroForOne ? key.currency1 : key.currency0;

        // Hook takes input from PM (mints claims to hook) — hook now has inputAmt claims
        inputCurrency.take(poolManager, address(this), inputAmount, true);

        // Hook settles netOutput to PM (burns netOutput claims from hook) — PM pays user
        outputCurrency.settle(poolManager, address(this), result.netOutput, true);

        // Fee accounting: hook took `inputAmt` input claims, spent `netOutput` output claims
        // At aiPrice: inputAmt * price = grossOutput. Fee = grossOutput - netOutput.
        // Hook's excess input claims value = fee (stays in pool, LP shares appreciate).
    }
}
