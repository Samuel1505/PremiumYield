// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "v4-core/libraries/FullMath.sol";

/// @title ILCalculator
/// @notice Library for computing impermanent loss from Uniswap v4 sqrtPriceX96 values
/// @dev Uses the standard IL formula: IL = 1 - 2*sqrt(r)/(1+r)
///      where r = (exitPrice / entryPrice)^2 is the actual price ratio.
///      Since sqrtPriceX96 = sqrt(actualPrice) * 2^96, the ratio of sqrtPrices equals sqrt(r).
library ILCalculator {
    uint256 internal constant SCALE = 1e9;
    uint256 internal constant SCALE_SQ = 1e18;
    uint256 internal constant BPS = 10_000;
    // Cap ratio at 1e27 so ratio^2 (1e54) fits safely in uint256
    uint256 internal constant MAX_RATIO_SCALED = 1e27;

    /// @notice Calculate impermanent loss in basis points
    /// @param entryPrice sqrtPriceX96 at LP deposit
    /// @param exitPrice  sqrtPriceX96 at LP withdrawal
    /// @return ilBps     IL expressed in basis points (0 if no price change)
    function calculate(uint256 entryPrice, uint256 exitPrice) internal pure returns (uint256 ilBps) {
        if (entryPrice == 0 || exitPrice == 0 || entryPrice == exitPrice) return 0;

        // Identify larger (b) and smaller (a) sqrtPrice so ratio ≥ 1.
        // IL is symmetric — price going up or down by the same factor produces the same IL.
        uint256 a = entryPrice < exitPrice ? entryPrice : exitPrice;
        uint256 b = entryPrice < exitPrice ? exitPrice : entryPrice;

        // k = (b/a) * SCALE  → normalized ratio in units of 1e9, always ≥ SCALE
        uint256 k = FullMath.mulDiv(b, SCALE, a);

        // Clamp to prevent k^2 overflow (any ratio > 1e18 is an extreme price move)
        if (k > MAX_RATIO_SCALED) k = MAX_RATIO_SCALED;

        // IL = 1 - 2*(a/b) / (1 + (a/b)^2)
        //    = 1 - 2*(1/k_norm) / (1 + 1/k_norm^2)   where k_norm = k/SCALE
        //    = 1 - 2*SCALE*k / (k^2 + SCALE_SQ)        after algebra
        // In bps: IL_bps = BPS - 2*BPS*SCALE*k / (k^2 + SCALE_SQ)
        //                = BPS - 2*BPS*SCALE*k / (k^2 + SCALE_SQ)
        // Note: numerator max = 2*10000*1e9*1e27 = 2e40; denominator max ≈ 1e54 — both fit uint256

        uint256 numerator = 2 * BPS * SCALE * k;
        uint256 denominator = k * k + SCALE_SQ;

        uint256 twoSqrtR_bps = numerator / denominator;

        // twoSqrtR_bps represents 2*sqrt(r)/(1+r) * 10000.
        // When price is unchanged (k == SCALE): twoSqrtR_bps = 2*BPS*SCALE^2/(SCALE^2+SCALE^2) = BPS → IL = 0.
        // When there's IL (k > SCALE): twoSqrtR_bps < BPS → IL > 0.
        if (twoSqrtR_bps >= BPS) return 0;
        return BPS - twoSqrtR_bps;
    }
}
