// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ILCalculator} from "../src/libraries/ILCalculator.sol";

/// @notice Extended IL math tests: additional price scenarios, edge cases, and invariant fuzz tests.
/// Companion to ILCalculator.t.sol — all 27 new tests live here.
contract ILCalculatorExtendedTest is Test {
    function calcIL(uint256 entry, uint256 exit) internal pure returns (uint256) {
        return ILCalculator.calculate(entry, exit);
    }

    // ── Additional known-value scenarios ──────────────────────────────────────

    // 1.5× actual price move: sqrtPrice ratio = sqrt(1.5) ≈ 1.22474
    // IL = 1 - 2*sqrt(1.5)/(1+1.5) = 1 - 2.44949/2.5 ≈ 0.0202 → ~202 bps
    function test_IL_1dot5xActualPriceMove() public pure {
        uint256 il = calcIL(1e18, 1_224_745e12); // sqrt(1.5) * 1e18
        assertApproxEqAbs(il, 202, 5);
    }

    // 3× actual price: sqrt(3) ≈ 1.73205
    // IL = 1 - 2*sqrt(3)/4 ≈ 0.134 → ~1340 bps
    function test_IL_3xActualPriceMove() public pure {
        uint256 il = calcIL(1e18, 1_732_051e12); // sqrt(3) * 1e18
        assertApproxEqAbs(il, 1340, 20);
    }

    // 5× actual price: sqrt(5) ≈ 2.23607
    // IL = 1 - 2*sqrt(5)/6 ≈ 0.2546 → ~2546 bps
    function test_IL_5xActualPriceMove() public pure {
        uint256 il = calcIL(1e18, 2_236_068e12); // sqrt(5) * 1e18
        assertApproxEqAbs(il, 2546, 20);
    }

    // 10× actual price: sqrt(10) ≈ 3.16228
    // IL = 1 - 2*sqrt(10)/11 ≈ 0.4250 → ~4250 bps
    function test_IL_10xActualPriceMove() public pure {
        uint256 il = calcIL(1e18, 3_162_278e12); // sqrt(10) * 1e18
        assertApproxEqAbs(il, 4250, 20);
    }

    // 25× actual price: sqrtPrice ratio = 5×
    // IL = 1 - 10/26 ≈ 0.6154 → ~6154 bps
    function test_IL_25xActualPriceMove() public pure {
        uint256 il = calcIL(1e18, 5e18); // 5× sqrtPrice = 25× actual price
        assertApproxEqAbs(il, 6154, 10);
    }

    // 50× actual price: sqrt(50) ≈ 7.07107
    // IL = 1 - 2*sqrt(50)/51 ≈ 0.7227 → ~7227 bps
    function test_IL_50xActualPriceMove() public pure {
        uint256 il = calcIL(1e18, 7_071_068e12); // sqrt(50) * 1e18
        assertApproxEqAbs(il, 7227, 20);
    }

    // 100× actual price: sqrtPrice ratio = 10×
    // IL = 1 - 20/101 ≈ 0.8020 → ~8020 bps
    function test_IL_100xActualPriceMove() public pure {
        uint256 il = calcIL(1e18, 10e18); // 10× sqrtPrice = 100× actual price
        assertApproxEqAbs(il, 8020, 20);
    }

    // sqrtPrice halved → 4× price drop; symmetric with 4× price up → 2000 bps
    function test_IL_sqrtPriceHalved_eq_4xPriceDrop() public pure {
        uint256 il = calcIL(1e18, 5e17); // 0.5× sqrtPrice
        assertApproxEqAbs(il, 2000, 5);
    }

    // sqrtPrice quartered → 16× price drop; same IL as sqrtPrice 4× up
    // IL = 1 - 8/17 ≈ 0.5294 → ~5294 bps
    function test_IL_sqrtPriceQuarter_eq_16xPriceDrop() public pure {
        uint256 il = calcIL(1e18, 25e16); // 0.25× sqrtPrice
        assertApproxEqAbs(il, 5294, 20);
    }

    // sqrtPrice × 0.1 → 100× price drop; same as 100× price up → 8020 bps
    function test_IL_sqrtPriceTenth_eq_100xPriceDrop() public pure {
        uint256 il = calcIL(1e18, 1e17); // 0.1× sqrtPrice
        assertApproxEqAbs(il, 8020, 30);
    }

    // 20% actual price move: sqrt(1.2) ≈ 1.09545
    // IL = 1 - 2*1.09545/2.2 ≈ 0.0041 → ~41 bps
    function test_IL_20pctActualPriceMove() public pure {
        uint256 il = calcIL(1e18, 1_095_445e12); // sqrt(1.2) * 1e18
        assertApproxEqAbs(il, 41, 5);
    }

    // Tiny values: entry=1, exit=2 (sqrtPrice 2× = 4× actual price → 2000 bps)
    function test_IL_tinyPrices_noOverflow() public pure {
        uint256 il = calcIL(1, 2);
        assertApproxEqAbs(il, 2000, 5);
    }

    // Extreme ratio: entry=1, exit=1e18 → k=MAX_RATIO_SCALED → IL=10000 bps exactly
    function test_IL_entryOne_exitLarge_maxIL() public pure {
        uint256 il = calcIL(1, 1e18);
        assertEq(il, 10_000);
    }

    // Diff of 1 unit from a large price → below 1 bps resolution, returns 0
    function test_IL_verySmallDiff() public pure {
        assertEq(calcIL(1e18, 1e18 + 1), 0);
    }

    // IL = 0 at the exact Uniswap v4 1:1 sqrtPriceX96 (2^96)
    function test_IL_zeroAtRealSqrtPriceX96() public pure {
        uint256 price = 79_228_162_514_264_337_593_543_950_336; // 2^96
        assertEq(calcIL(price, price), 0);
    }

    // ── Structural properties ─────────────────────────────────────────────────

    // Swapping entry and exit gives the same IL (the formula is symmetric)
    function test_IL_entryExitSwap_sameResult() public pure {
        assertEq(calcIL(1e18, 2e18), calcIL(2e18, 1e18));
        assertEq(calcIL(1e18, 3e18), calcIL(3e18, 1e18));
    }

    // IL is symmetric: 3× up ≈ 1/3× down (minor integer rounding allowed)
    function test_IL_symmetry_3x() public pure {
        uint256 up = calcIL(1e18, 1_732_051e12); // sqrt(3) * entry
        uint256 down = calcIL(1e18, 577_350e12); // (1/sqrt(3)) * entry
        assertApproxEqAbs(up, down, 5);
    }

    // IL is symmetric: 10× up ≈ 0.1× down
    function test_IL_symmetry_10x() public pure {
        uint256 up = calcIL(1e18, 3_162_278e12); // sqrt(10) * entry
        uint256 down = calcIL(1e18, 316_228e12); // (1/sqrt(10)) * entry
        assertApproxEqAbs(up, down, 10);
    }

    // Larger price divergence → larger IL (strict monotonicity along a direction)
    function test_IL_monotonic_stepwise() public pure {
        uint256 entry = 1e18;
        uint256 il2x = calcIL(entry, 2e18); // 4× actual price
        uint256 il3x = calcIL(entry, 3e18); // 9× actual price
        uint256 il5x = calcIL(entry, 5e18); // 25× actual price
        uint256 il10x = calcIL(entry, 10e18); // 100× actual price
        assertLt(il2x, il3x);
        assertLt(il3x, il5x);
        assertLt(il5x, il10x);
    }

    // Extreme ratio should never revert and should return IL near 10000 bps
    function test_IL_extremeRatio_noOverflow() public pure {
        uint256 il = calcIL(1, type(uint128).max);
        assertGe(il, 9_999);
        assertLe(il, 10_000);
    }

    // Realistic Q96-scale entry with a small percentage move
    function test_IL_realisticQ96_smallMove() public pure {
        uint256 entry = 1e30; // Q96-magnitude proxy
        uint256 exit = entry + (entry * 5 / 100); // 5% sqrtPrice move ≈ 10.25% actual price move
        uint256 il = calcIL(entry, exit);
        assertLe(il, 300);
        assertGe(il, 0);
    }

    // IL = 0 at identical prices across different magnitude scales
    function test_IL_exactZero_variousScales() public pure {
        assertEq(calcIL(1, 1), 0);
        assertEq(calcIL(1e9, 1e9), 0);
        assertEq(calcIL(1e18, 1e18), 0);
        assertEq(calcIL(1e30, 1e30), 0);
    }

    // ── Fuzz tests ────────────────────────────────────────────────────────────

    // IL is always in [0, BPS] for all uint128 inputs
    function test_fuzz_IL_alwaysBounded(uint128 entry, uint128 exit) public pure {
        vm.assume(entry > 0 && exit > 0);
        uint256 il = ILCalculator.calculate(entry, exit);
        assertLe(il, 10_000);
    }

    // IL(entry, exit) == IL(exit, entry) — perfect symmetry
    function test_fuzz_IL_symmetricInputs(uint128 entry, uint128 exit) public pure {
        vm.assume(entry > 0 && exit > 0);
        assertEq(ILCalculator.calculate(entry, exit), ILCalculator.calculate(exit, entry));
    }

    // IL is always 0 when entry == exit
    function test_fuzz_IL_zeroWhenSamePrice(uint128 price) public pure {
        vm.assume(price > 0);
        assertEq(ILCalculator.calculate(price, price), 0);
    }

    // Larger divergence from entry gives larger IL (monotonicity)
    function test_fuzz_IL_monotonic(uint64 entry, uint8 smallFactor, uint8 largeFactor) public pure {
        vm.assume(entry > 1e6);
        vm.assume(smallFactor >= 2 && smallFactor < largeFactor);
        uint256 exitSmall = uint256(entry) * smallFactor;
        uint256 exitLarge = uint256(entry) * largeFactor;
        vm.assume(exitLarge < type(uint128).max);
        assertLe(ILCalculator.calculate(entry, exitSmall), ILCalculator.calculate(entry, exitLarge));
    }

    // Scaling both entry and exit by the same constant leaves IL unchanged (within ±2 bps rounding)
    function test_fuzz_IL_scaleInvariant(uint48 entry, uint48 exit, uint16 scale) public pure {
        vm.assume(entry > 1 && exit > 1);
        vm.assume(scale > 0);
        vm.assume(uint256(entry) * scale < type(uint128).max);
        vm.assume(uint256(exit) * scale < type(uint128).max);
        uint256 il1 = ILCalculator.calculate(entry, exit);
        uint256 il2 = ILCalculator.calculate(uint256(entry) * scale, uint256(exit) * scale);
        uint256 diff = il1 > il2 ? il1 - il2 : il2 - il1;
        assertLe(diff, 2);
    }
}
