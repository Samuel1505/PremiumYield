// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";

import {PremiumYieldHook} from "../src/PremiumYieldHook.sol";
import {IVolatilityOracle} from "../src/interfaces/IVolatilityOracle.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC4626Vault} from "./mocks/MockERC4626Vault.sol";
import {MockVolatilityOracle} from "./mocks/MockVolatilityOracle.sol";

/// @notice Admin, access-control, constants, permissions, and premium-precision tests.
contract HookAdminTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
    );

    PoolManager poolManager;
    PoolModifyLiquidityTest liquidityRouter;

    MockERC20 token0;
    MockERC20 token1;
    MockERC4626Vault vault;
    MockVolatilityOracle oracle;
    PremiumYieldHook hook;

    PoolKey poolKey;
    bytes32 poolId;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address admin = makeAddr("admin");

    int24 constant TICK_LOWER = -887220;
    int24 constant TICK_UPPER = 887220;
    uint160 constant INITIAL_SQRT_PRICE = 79228162514264337593543950336;
    int256 constant LIQUIDITY = 1_000_000e18;

    function setUp() public {
        vm.startPrank(admin);

        poolManager = new PoolManager(admin);

        MockERC20 tokenA = new MockERC20("TokenA", "TKNA", 18);
        MockERC20 tokenB = new MockERC20("TokenB", "TKNB", 18);
        if (address(tokenA) > address(tokenB)) (tokenA, tokenB) = (tokenB, tokenA);
        token0 = tokenA;
        token1 = tokenB;

        vault = new MockERC4626Vault(address(token0));
        oracle = new MockVolatilityOracle(1, 3_000);

        PremiumYieldHook hookImpl = new PremiumYieldHook(poolManager, IVolatilityOracle(address(oracle)));
        vm.etch(address(HOOK_FLAGS), address(hookImpl).code);
        hook = PremiumYieldHook(address(HOOK_FLAGS));

        poolKey = PoolKey({
            currency0: Currency.wrap(address(token0)),
            currency1: Currency.wrap(address(token1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(HOOK_FLAGS))
        });
        poolId = PoolId.unwrap(poolKey.toId());
        hook.setPoolVault(poolId, address(vault));
        poolManager.initialize(poolKey, INITIAL_SQRT_PRICE);

        liquidityRouter = new PoolModifyLiquidityTest(poolManager);
        vm.stopPrank();

        token0.mint(alice, 100_000_000e18);
        token1.mint(alice, 100_000_000e18);
        token0.mint(bob, 100_000_000e18);
        token1.mint(bob, 100_000_000e18);
    }

    function _addLiquidityInsured(address actor, uint256 thresholdBps, int256 liquidityDelta) internal {
        vm.startPrank(actor);
        token0.approve(address(liquidityRouter), type(uint256).max);
        token1.approve(address(liquidityRouter), type(uint256).max);
        token0.approve(address(hook), type(uint256).max);
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: liquidityDelta, salt: bytes32(0)
        });
        liquidityRouter.modifyLiquidity(poolKey, params, abi.encode(thresholdBps, true, actor));
        vm.stopPrank();
    }

    // ── setPoolVault ──────────────────────────────────────────────────────────

    function test_setPoolVault_onlyOwner_succeeds() public {
        address newVault = makeAddr("newVault");
        vm.prank(admin);
        hook.setPoolVault(poolId, newVault); // should not revert
        assertEq(hook.poolVault(poolId), newVault);
    }

    function test_setPoolVault_nonOwner_reverts() public {
        vm.prank(alice);
        vm.expectRevert(PremiumYieldHook.NotOwner.selector);
        hook.setPoolVault(poolId, makeAddr("x"));
    }

    function test_setPoolVault_updatesPoolVaultStorage() public {
        address newVault = makeAddr("vaultZ");
        vm.prank(admin);
        hook.setPoolVault(poolId, newVault);
        assertEq(hook.poolVault(poolId), newVault);
    }

    function test_setPoolVault_emitsPoolVaultSet() public {
        address newVault = makeAddr("vaultEvent");
        vm.expectEmit(true, false, false, true);
        emit PremiumYieldHook.PoolVaultSet(poolId, newVault);
        vm.prank(admin);
        hook.setPoolVault(poolId, newVault);
    }

    function test_setPoolVault_canOverwriteExistingVault() public {
        address vaultA = makeAddr("vaultA");
        address vaultB = makeAddr("vaultB");
        vm.prank(admin);
        hook.setPoolVault(poolId, vaultA);
        vm.prank(admin);
        hook.setPoolVault(poolId, vaultB);
        assertEq(hook.poolVault(poolId), vaultB);
    }

    // ── pauseDeposits ─────────────────────────────────────────────────────────

    function test_pauseDeposits_onlyOwner_succeeds() public {
        vm.prank(admin);
        hook.pauseDeposits(poolId); // should not revert
        assertTrue(hook.depositsPausedMap(poolId));
    }

    function test_pauseDeposits_nonOwner_reverts() public {
        vm.prank(alice);
        vm.expectRevert(PremiumYieldHook.NotOwner.selector);
        hook.pauseDeposits(poolId);
    }

    function test_pauseDeposits_setsFlagToTrue() public {
        assertFalse(hook.depositsPausedMap(poolId));
        vm.prank(admin);
        hook.pauseDeposits(poolId);
        assertTrue(hook.depositsPausedMap(poolId));
    }

    function test_pauseDeposits_emitsEvent() public {
        vm.expectEmit(true, false, false, false);
        emit PremiumYieldHook.DepositsPausedEvent(poolId);
        vm.prank(admin);
        hook.pauseDeposits(poolId);
    }

    // ── resumeDeposits ────────────────────────────────────────────────────────

    function test_resumeDeposits_onlyOwner_succeeds() public {
        vm.prank(admin);
        hook.pauseDeposits(poolId);
        vm.prank(admin);
        hook.resumeDeposits(poolId); // should not revert
        assertFalse(hook.depositsPausedMap(poolId));
    }

    function test_resumeDeposits_nonOwner_reverts() public {
        vm.prank(alice);
        vm.expectRevert(PremiumYieldHook.NotOwner.selector);
        hook.resumeDeposits(poolId);
    }

    function test_resumeDeposits_clearsFlagToFalse() public {
        vm.prank(admin);
        hook.pauseDeposits(poolId);
        assertTrue(hook.depositsPausedMap(poolId));
        vm.prank(admin);
        hook.resumeDeposits(poolId);
        assertFalse(hook.depositsPausedMap(poolId));
    }

    function test_resumeDeposits_emitsEvent() public {
        vm.prank(admin);
        hook.pauseDeposits(poolId);
        vm.expectEmit(true, false, false, false);
        emit PremiumYieldHook.DepositsResumedEvent(poolId);
        vm.prank(admin);
        hook.resumeDeposits(poolId);
    }

    // ── Constants ─────────────────────────────────────────────────────────────

    function test_constant_basePremiumBps_is5() public view {
        assertEq(hook.BASE_PREMIUM_BPS(), 5);
    }

    function test_constant_minSolvencyRatio_is11000() public view {
        assertEq(hook.MIN_SOLVENCY_RATIO_BPS(), 11_000);
    }

    function test_constant_solvencyWarning_is12000() public view {
        assertEq(hook.SOLVENCY_WARNING_BPS(), 12_000);
    }

    function test_constant_minCoverageBps_is1() public view {
        assertEq(hook.MIN_COVERAGE_BPS(), 1);
    }

    function test_constant_maxCoverageBps_is5000() public view {
        assertEq(hook.MAX_COVERAGE_BPS(), 5_000);
    }

    // ── Hook permissions ──────────────────────────────────────────────────────

    function test_hookPermissions_correctFlags() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeAddLiquidity, "beforeAddLiquidity must be set");
        assertTrue(p.afterRemoveLiquidity, "afterRemoveLiquidity must be set");
        assertTrue(p.afterRemoveLiquidityReturnDelta, "afterRemoveLiquidityReturnDelta must be set");
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.beforeSwap);
        assertFalse(p.afterSwap);
        assertFalse(p.beforeInitialize);
        assertFalse(p.afterInitialize);
    }

    // ── getSolvencyRatio ──────────────────────────────────────────────────────

    function test_getSolvencyRatio_noLiability_returnsMax() public view {
        // No insured positions added yet — liability = 0
        assertEq(hook.getSolvencyRatio(poolId), type(uint256).max);
    }

    function test_getSolvencyRatio_noVaultSet_returnsMax() public view {
        bytes32 unknownPool = bytes32(uint256(0xDEAD));
        assertEq(hook.getSolvencyRatio(unknownPool), type(uint256).max);
    }

    function test_getSolvencyRatio_calculated() public {
        _addLiquidityInsured(alice, 300, LIQUIDITY);
        uint256 vaultAssets = vault.totalAssets();
        uint256 liability = hook.totalCoverageLiability(poolId);
        assertGt(liability, 0);
        uint256 expected = vaultAssets * 10_000 / liability;
        assertEq(hook.getSolvencyRatio(poolId), expected);
    }

    // ── onlyPoolManager guard ─────────────────────────────────────────────────

    function test_directCall_beforeAddLiquidity_reverts() public {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: LIQUIDITY, salt: bytes32(0)
        });
        vm.expectRevert(PremiumYieldHook.NotPoolManager.selector);
        hook.beforeAddLiquidity(alice, poolKey, params, bytes(""));
    }

    function test_directCall_afterRemoveLiquidity_reverts() public {
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: -LIQUIDITY, salt: bytes32(0)
        });
        vm.expectRevert(PremiumYieldHook.NotPoolManager.selector);
        hook.afterRemoveLiquidity(alice, poolKey, params, BalanceDelta.wrap(0), BalanceDelta.wrap(0), bytes(""));
    }

    // ── Premium precision ─────────────────────────────────────────────────────
    // At 1:1 price, notional = LIQUIDITY exactly.
    // premiumBps = BASE_PREMIUM_BPS * multiplier / 100 (integer division).
    // Calm (0): 5*100/100=5 → premium = LIQUIDITY*5/10000
    // Normal (1): 5*150/100=7 → premium = LIQUIDITY*7/10000
    // Elevated (2): 5*250/100=12 → premium = LIQUIDITY*12/10000
    // Extreme (3): 5*400/100=20 → premium = LIQUIDITY*20/10000

    function test_premium_calm_exact() public {
        oracle.setRegime(0);
        uint256 before = vault.totalAssets();
        _addLiquidityInsured(alice, 300, LIQUIDITY);
        assertEq(vault.totalAssets() - before, uint256(int256(LIQUIDITY)) * 5 / 10_000);
    }

    function test_premium_normal_exact() public {
        oracle.setRegime(1);
        uint256 before = vault.totalAssets();
        _addLiquidityInsured(alice, 300, LIQUIDITY);
        assertEq(vault.totalAssets() - before, uint256(int256(LIQUIDITY)) * 7 / 10_000);
    }

    function test_premium_elevated_exact() public {
        oracle.setRegime(2);
        uint256 before = vault.totalAssets();
        _addLiquidityInsured(alice, 300, LIQUIDITY);
        assertEq(vault.totalAssets() - before, uint256(int256(LIQUIDITY)) * 12 / 10_000);
    }

    function test_premium_extreme_exact() public {
        oracle.setRegime(3);
        uint256 before = vault.totalAssets();
        _addLiquidityInsured(alice, 300, LIQUIDITY);
        assertEq(vault.totalAssets() - before, uint256(int256(LIQUIDITY)) * 20 / 10_000);
    }

    // ── Coverage liability ────────────────────────────────────────────────────

    function test_coverageLiability_incrementsCorrectly() public {
        uint256 before = hook.totalCoverageLiability(poolId);
        _addLiquidityInsured(alice, 300, LIQUIDITY);
        uint256 after_ = hook.totalCoverageLiability(poolId);
        // maxCoverage = (10000 - 300) * notional / 10000 = 9700 * LIQUIDITY / 10000
        uint256 expected = (10_000 - 300) * uint256(int256(LIQUIDITY)) / 10_000;
        assertEq(after_ - before, expected);
    }
}
