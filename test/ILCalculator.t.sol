// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ILCalculator} from "../src/libraries/ILCalculator.sol";

/// @notice Unit tests for the ILCalculator library
/// IL formula: 1 - 2*sqrt(r)/(1+r) where r = (exit/entry)^2 (actual price ratio)
/// Since inputs are sqrtPriceX96-style values: sqrt(r) = exit/entry
contract ILCalculatorTest is Test {
    // Helper to expose the library as an external call
    function calcIL(uint256 entry, uint256 exit) internal pure returns (uint256) {
        return ILCalculator.calculate(entry, exit);
    }

    // ── Zero / Edge Cases ─────────────────────────────────────────────────

    function test_noIL_samePrice() public pure {
        assertEq(calcIL(1e18, 1e18), 0);
    }

    function test_noIL_zeroEntry() public pure {
        assertEq(calcIL(0, 1e18), 0);
    }

    function test_noIL_zeroExit() public pure {
        assertEq(calcIL(1e18, 0), 0);
    }

    // ── Known price moves ─────────────────────────────────────────────────
    // Using 1e18 as the entry sqrtPrice baseline.
    // Actual price ratio = (exit/entry)^2, so exit = entry * sqrt(priceRatio).

    // 2× actual price move → exit sqrtPrice = entry * √2 ≈ 1.41421 × entry
    // IL = 1 - 2*(1/√2)/(1 + 1/2) = 1 - 2*0.7071/1.5 = 1 - 0.9428 = 0.0572 → ~572 bps
    function test_IL_2xPriceMove() public pure {
        uint256 entry = 1e18;
        uint256 exit = 1.41421356e18; // √2 × entry
        uint256 il = calcIL(entry, exit);
        // Expect ~572 bps; allow ±10 bps tolerance for integer arithmetic
        assertApproxEqAbs(il, 572, 10);
    }

    // 4× actual price move → exit sqrtPrice = entry * 2
    // IL = 1 - 2*(1/2)/(1 + 1/4) = 1 - 1/1.25 = 1 - 0.8 = 0.2 → 2000 bps
    function test_IL_4xPriceMove() public pure {
        uint256 entry = 1e18;
        uint256 exit = 2e18; // 2× sqrtPrice = 4× actual price
        uint256 il = calcIL(entry, exit);
        assertApproxEqAbs(il, 2000, 10);
    }

    // 9× actual price move → exit sqrtPrice = entry * 3
    // IL = 1 - 2*(1/3)/(1 + 1/9) = 1 - (2/3)/(10/9) = 1 - (2/3)*(9/10) = 1 - 0.6 = 0.4 → 4000 bps
    function test_IL_9xPriceMove() public pure {
        uint256 entry = 1e18;
        uint256 exit = 3e18; // 3× sqrtPrice = 9× actual price
        uint256 il = calcIL(entry, exit);
        assertApproxEqAbs(il, 4000, 10);
    }

    // Symmetry: price up by X or down by X yields same IL
    function test_IL_symmetry() public pure {
        uint256 entry = 1e18;
        uint256 exit_up = 2e18;
        uint256 exit_down = 0.5e18; // price dropped 4×
        assertApproxEqAbs(calcIL(entry, exit_up), calcIL(entry, exit_down), 1);
    }

    // Very small price move → near-zero IL (≤ 1 bps)
    function test_IL_smallMove() public pure {
        uint256 entry = 1e18;
        uint256 exit = 1.001e18; // 0.1% sqrtPrice change ≈ 0.02% actual price move
        uint256 il = calcIL(entry, exit);
        assertLe(il, 1); // at most 1 bps due to integer rounding
    }

    // Extreme price move (100× sqrtPrice = 10000× actual price)
    // IL = 1 - 2*(1/100)/(1 + 1/10000) ≈ 1 - 0.02/1.0001 ≈ 0.98 → ~9800 bps
    function test_IL_extremeMove() public pure {
        uint256 entry = 1e18;
        uint256 exit = 100e18; // 100× sqrtPrice
        uint256 il = calcIL(entry, exit);
        assertGt(il, 9700);
        assertLe(il, 10000);
    }

    // IL is always < 10000 bps (never exceeds 100%)
    function test_IL_neverExceedsBps(uint256 entry, uint256 exit) public pure {
        vm.assume(entry > 0 && exit > 0);
        vm.assume(entry < type(uint128).max && exit < type(uint128).max);
        assertLe(ILCalculator.calculate(entry, exit), 10_000);
    }

    // ── Real sqrtPriceX96 values ──────────────────────────────────────────
    // ETH/USDC pool around $2000: sqrtPriceX96 ≈ 1580.9 * 2^96 / sqrt(1e12)
    // Using approximate values for a realistic scenario
    function test_IL_realSqrtPrices_10pctMove() public pure {
        // sqrtPrice corresponding to ETH = $2000 (normalized, not actual Q96)
        uint256 entryPrice = 1_000_000e9; // ~$2000
        // 10% price increase → sqrtPrice increases by ~sqrt(1.1) ≈ 1.0488×
        uint256 exitPrice = 1_048_809e9;
        uint256 il = calcIL(entryPrice, exitPrice);
        // ~10% price move → ~0.12% IL = ~12 bps
        assertApproxEqAbs(il, 12, 3);
    }
}
