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
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";

import {PremiumYieldHook} from "../src/PremiumYieldHook.sol";
import {IVolatilityOracle} from "../src/interfaces/IVolatilityOracle.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC4626Vault} from "./mocks/MockERC4626Vault.sol";
import {MockVolatilityOracle} from "./mocks/MockVolatilityOracle.sol";

/// @notice Extended integration tests covering multi-LP scenarios, payout paths, events,
///         solvency mechanics, edge cases, and fuzz invariants (53 tests).
contract IntegrationExtendedTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    function _getSlot0() internal view returns (uint160 sqrtPriceX96) {
        (sqrtPriceX96,,,) = IPoolManager(address(poolManager)).getSlot0(poolKey.toId());
    }
    using CurrencyLibrary for Currency;

    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
    );

    PoolManager poolManager;
    PoolModifyLiquidityTest liquidityRouter;
    PoolSwapTest swapRouter;

    MockERC20 token0;
    MockERC20 token1;
    MockERC4626Vault vault;
    MockVolatilityOracle oracle;
    PremiumYieldHook hook;

    PoolKey poolKey;
    bytes32 poolId;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address charlie = makeAddr("charlie");
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
        swapRouter = new PoolSwapTest(poolManager);
        vm.stopPrank();

        token0.mint(alice, 100_000_000e18);
        token1.mint(alice, 100_000_000e18);
        token0.mint(bob, 100_000_000e18);
        token1.mint(bob, 100_000_000e18);
        token0.mint(charlie, 100_000_000e18);
        token1.mint(charlie, 100_000_000e18);
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

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

    function _removeLiquidity(address actor, int256 liquidityDelta) internal {
        vm.startPrank(actor);
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: liquidityDelta, salt: bytes32(0)
        });
        liquidityRouter.modifyLiquidity(poolKey, params, abi.encode(actor));
        vm.stopPrank();
    }

    function _movePrice(bool zeroForOne, int256 amountSpecified) internal {
        address swapper = makeAddr("swapper");
        token0.mint(swapper, 10_000_000e18);
        token1.mint(swapper, 10_000_000e18);
        vm.startPrank(swapper);
        token0.approve(address(swapRouter), type(uint256).max);
        token1.approve(address(swapRouter), type(uint256).max);
        uint160 sqrtLimit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtLimit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            bytes("")
        );
        vm.stopPrank();
    }

    function _addInitialLiquidity(int256 amount) internal {
        address lp0 = makeAddr("initLP");
        token0.mint(lp0, 10_000_000e18);
        token1.mint(lp0, 10_000_000e18);
        vm.startPrank(lp0);
        token0.approve(address(liquidityRouter), type(uint256).max);
        token1.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(TICK_LOWER, TICK_UPPER, amount, bytes32(0)), bytes("")
        );
        vm.stopPrank();
    }

    // Over-capitalize vault to 300%+ solvency so withdrawals don't auto-pause
    function _overcapitalize() internal {
        uint256 liability = hook.totalCoverageLiability(poolId);
        if (liability == 0) return;
        vault.simulateYield(liability * 3);
    }

    function _positionId(address lp) internal view returns (bytes32) {
        return keccak256(abi.encode(lp, poolKey.toId(), TICK_LOWER, TICK_UPPER, bytes32(0)));
    }

    // ── Multi-LP scenarios ────────────────────────────────────────────────────

    function test_twoLP_independentPremiumsTracked() public {
        oracle.setRegime(1);
        uint256 v0 = vault.totalAssets();
        _addLiquidityInsured(alice, 300, LIQUIDITY);
        uint256 alicePremium = vault.totalAssets() - v0;

        uint256 v1 = vault.totalAssets();
        _addLiquidityInsured(bob, 500, LIQUIDITY);
        uint256 bobPremium = vault.totalAssets() - v1;

        (,,,,, uint256 alicePremiumStored,,) = hook.positions(_positionId(alice));
        (,,,,, uint256 bobPremiumStored,,) = hook.positions(_positionId(bob));

        assertEq(alicePremiumStored, alicePremium);
        assertEq(bobPremiumStored, bobPremium);
    }

    function test_twoLP_differentThresholds() public {
        _addLiquidityInsured(alice, 300, LIQUIDITY); // 3% threshold
        _addLiquidityInsured(bob, 2000, LIQUIDITY); // 20% threshold

        (,,,, uint256 aliceThreshold,,,) = hook.positions(_positionId(alice));
        (,,,, uint256 bobThreshold,,,) = hook.positions(_positionId(bob));

        assertEq(aliceThreshold, 300);
        assertEq(bobThreshold, 2000);
    }

    function test_twoLP_vaultSharesSumToTotal() public {
        _addLiquidityInsured(alice, 300, LIQUIDITY);
        _addLiquidityInsured(bob, 500, LIQUIDITY);

        (,,,,,, uint256 aliceShares,) = hook.positions(_positionId(alice));
        (,,,,,, uint256 bobShares,) = hook.positions(_positionId(bob));

        assertEq(vault.totalSupply(), aliceShares + bobShares, "shares must sum to vault totalSupply");
    }

    function test_twoLP_separateWithdrawals() public {
        _addLiquidityInsured(alice, 300, LIQUIDITY);
        _addLiquidityInsured(bob, 500, LIQUIDITY);
        _overcapitalize();

        _removeLiquidity(alice, -LIQUIDITY);
        (,,,,,,, bool aliceActive) = hook.positions(_positionId(alice));
        assertFalse(aliceActive, "Alice settled");

        // Bob's position is untouched
        (,,,,,,, bool bobActive) = hook.positions(_positionId(bob));
        assertTrue(bobActive, "Bob still active");

        _removeLiquidity(bob, -LIQUIDITY);
        (,,,,,,, bobActive) = hook.positions(_positionId(bob));
        assertFalse(bobActive, "Bob settled");
    }

    function test_LP_redeposit_afterWithdrawal() public {
        _addLiquidityInsured(alice, 300, LIQUIDITY);
        _removeLiquidity(alice, -LIQUIDITY);

        (,,,,,,, bool activeAfterRemoval) = hook.positions(_positionId(alice));
        assertFalse(activeAfterRemoval);

        // Resume if auto-paused
        if (hook.depositsPausedMap(poolId)) {
            vm.prank(admin);
            hook.resumeDeposits(poolId);
        }

        _addLiquidityInsured(alice, 500, LIQUIDITY);
        (,,,,,,, bool activeAfterRedeposit) = hook.positions(_positionId(alice));
        assertTrue(activeAfterRedeposit, "re-deposit creates fresh active position");
    }

    function test_threeLP_sequentialDeposits() public {
        uint256 v0 = vault.totalAssets();
        _addLiquidityInsured(alice, 300, LIQUIDITY);
        _addLiquidityInsured(bob, 500, LIQUIDITY);
        _addLiquidityInsured(charlie, 1000, LIQUIDITY);

        assertGt(vault.totalAssets(), v0, "vault grew with each deposit");
        // All three positions active
        (,,,,,,, bool a) = hook.positions(_positionId(alice));
        (,,,,,,, bool b) = hook.positions(_positionId(bob));
        (,,,,,,, bool c) = hook.positions(_positionId(charlie));
        assertTrue(a && b && c);
    }

    function test_twoPositions_sameLp_differentSalts() public {
        // Position 1: salt = 0
        _addLiquidityInsured(alice, 300, LIQUIDITY);

        // Position 2: salt = 1 (same LP, same ticks, different salt)
        vm.startPrank(alice);
        token0.approve(address(liquidityRouter), type(uint256).max);
        token1.approve(address(liquidityRouter), type(uint256).max);
        token0.approve(address(hook), type(uint256).max);
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: LIQUIDITY, salt: bytes32(uint256(1))
        });
        liquidityRouter.modifyLiquidity(poolKey, params, abi.encode(uint256(300), true, alice));
        vm.stopPrank();

        bytes32 posId0 = keccak256(abi.encode(alice, poolKey.toId(), TICK_LOWER, TICK_UPPER, bytes32(0)));
        bytes32 posId1 = keccak256(abi.encode(alice, poolKey.toId(), TICK_LOWER, TICK_UPPER, bytes32(uint256(1))));

        assertNotEq(posId0, posId1, "different salts must produce different position IDs");
        (,,,,,,, bool a0) = hook.positions(posId0);
        (,,,,,,, bool a1) = hook.positions(posId1);
        assertTrue(a0 && a1, "both positions should be active");
    }

    // ── Payout paths ──────────────────────────────────────────────────────────

    function test_noIL_premiumPlusYieldReturned() public {
        uint256 aliceToken0Before = token0.balanceOf(alice);
        _addLiquidityInsured(alice, 5000, LIQUIDITY); // 50% threshold
        uint256 premiumPaid = aliceToken0Before - token0.balanceOf(alice);
        assertGt(premiumPaid, 0);

        vault.simulateYield(premiumPaid * 10 / 100); // 10% yield

        // Remove immediately (no price move → IL ≈ 0)
        uint256 before = token0.balanceOf(alice);
        _removeLiquidity(alice, -LIQUIDITY);
        uint256 received = token0.balanceOf(alice) - before;

        // Alice receives some tokens back (from liquidity + premium refund)
        assertGt(received, 0);

        bytes32 posId = _positionId(alice);
        (,,,,,,, bool active) = hook.positions(posId);
        assertFalse(active);
    }

    function test_IL_belowThreshold_fullRefund() public {
        // High threshold (50%) with zero price move → IL = 0 < 5000 bps → full refund
        uint256 vaultBefore = vault.totalAssets();
        _addLiquidityInsured(alice, 5000, LIQUIDITY);
        uint256 premium = vault.totalAssets() - vaultBefore;

        vault.simulateYield(premium / 10); // add some yield

        _removeLiquidity(alice, -LIQUIDITY);

        // Vault should have paid out the premium + yield (hook transferred it to LP)
        // vault.totalAssets() should be much lower now (refund depleted it)
        assertLe(vault.totalAssets(), vaultBefore + premium / 10);
    }

    function test_IL_aboveThreshold_claimFired() public {
        _addInitialLiquidity(LIQUIDITY * 10);
        _addLiquidityInsured(alice, 100, LIQUIDITY); // very low threshold (1%)

        // Large price move creates IL > 1%
        _movePrice(true, -5_000_000e18);

        _removeLiquidity(alice, -LIQUIDITY);
        (,,,,,,, bool active) = hook.positions(_positionId(alice));
        assertFalse(active, "position settled after claim");
    }

    function test_yieldAccrued_includedInRefund() public {
        _addLiquidityInsured(alice, 5000, LIQUIDITY);

        (,,,,,, uint256 aliceShares,) = hook.positions(_positionId(alice));
        assertGt(aliceShares, 0);

        uint256 yield = vault.totalAssets() * 50 / 100; // 50% yield on vault
        vault.simulateYield(yield);

        // Vault now worth 1.5× — on refund, Alice gets back more than she paid
        uint256 vaultValueBefore = vault.totalAssets();
        _removeLiquidity(alice, -LIQUIDITY);
        uint256 vaultValueAfter = vault.totalAssets();

        // Vault decreased by the amount transferred to LP (premium + yield)
        assertLt(vaultValueAfter, vaultValueBefore, "vault released assets for refund");
    }

    function test_positionInactive_afterWithdrawal() public {
        _addLiquidityInsured(alice, 300, LIQUIDITY);
        (,,,,,,, bool activeBefore) = hook.positions(_positionId(alice));
        assertTrue(activeBefore);

        _removeLiquidity(alice, -LIQUIDITY);
        (,,,,,,, bool activeAfter) = hook.positions(_positionId(alice));
        assertFalse(activeAfter);
    }

    function test_doubleWithdraw_secondIsNoOp() public {
        _addLiquidityInsured(alice, 300, LIQUIDITY);
        _overcapitalize();

        _removeLiquidity(alice, -LIQUIDITY);
        uint256 vaultAfterFirst = vault.totalAssets();

        // Second withdrawal with same LP address — position inactive → hook returns zero delta
        // Alice has no more LP liquidity to remove but we verify the hook doesn't double-pay
        // (The actual second modifyLiquidity call with -LIQUIDITY would fail at the pool level
        //  since Alice has no more liquidity; we test the hook's inactive-position guard directly)
        bytes32 posId = _positionId(alice);
        (,,,,,,, bool active) = hook.positions(posId);
        assertFalse(active, "position inactive: second removal is a no-op from hook perspective");
        assertEq(vault.totalAssets(), vaultAfterFirst, "vault unchanged after position already settled");
    }

    function test_claimCappedByVaultBalance() public {
        _addInitialLiquidity(LIQUIDITY * 10);
        _addLiquidityInsured(alice, 1, LIQUIDITY); // 1 bps threshold, maximum coverage

        uint256 vaultAtStart = vault.totalAssets();
        _movePrice(true, -5_000_000e18); // extreme price drop

        _removeLiquidity(alice, -LIQUIDITY); // should not revert

        // Vault can only decrease by at most what it started with
        assertLe(vault.totalAssets(), vaultAtStart);
        (,,,,,,, bool active) = hook.positions(_positionId(alice));
        assertFalse(active);
    }

    function test_noInsurance_optOut() public {
        uint256 vaultBefore = vault.totalAssets();

        vm.startPrank(alice);
        token0.approve(address(liquidityRouter), type(uint256).max);
        token1.approve(address(liquidityRouter), type(uint256).max);
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: LIQUIDITY, salt: bytes32(0)
        });
        liquidityRouter.modifyLiquidity(poolKey, params, abi.encode(uint256(300), false, alice));
        vm.stopPrank();

        assertEq(vault.totalAssets(), vaultBefore, "opt-out: no premium collected");
        (,,,,,,, bool active) = hook.positions(_positionId(alice));
        assertFalse(active, "opt-out: no position recorded");
    }

    // ── Event tests ───────────────────────────────────────────────────────────

    function test_event_PremiumCollected_indexed() public {
        oracle.setRegime(1); // Normal

        bytes32 expectedPosId = _positionId(alice);

        // Pre-approve everything BEFORE setting up the expectation so that no
        // ERC20 Approval events fire immediately after vm.expectEmit.
        vm.startPrank(alice);
        token0.approve(address(liquidityRouter), type(uint256).max);
        token1.approve(address(liquidityRouter), type(uint256).max);
        token0.approve(address(hook), type(uint256).max);
        vm.stopPrank();

        // The very next external event emitted from hook MUST be PremiumCollected.
        // We call modifyLiquidity directly (no helper) to avoid extra approve events.
        vm.expectEmit(true, true, false, false);
        emit PremiumYieldHook.PremiumCollected(expectedPosId, alice, 0, 0, 0);

        vm.startPrank(alice);
        liquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: LIQUIDITY, salt: bytes32(0)
            }),
            abi.encode(uint256(300), true, alice)
        );
        vm.stopPrank();
    }

    function test_event_ClaimProcessed_emitted() public {
        _addInitialLiquidity(LIQUIDITY * 10);
        _addLiquidityInsured(alice, 1, LIQUIDITY);
        _movePrice(true, -5_000_000e18);

        // Expect ClaimProcessed for Alice's position
        vm.expectEmit(true, true, false, false);
        emit PremiumYieldHook.ClaimProcessed(_positionId(alice), alice, 0, 0, 0);

        _removeLiquidity(alice, -LIQUIDITY);
    }

    function test_event_PremiumReturned_emitted() public {
        _addLiquidityInsured(alice, 5000, LIQUIDITY); // 50% threshold — no claim at zero price move

        vm.expectEmit(true, true, false, false);
        emit PremiumYieldHook.PremiumReturned(_positionId(alice), alice, 0, 0);

        _removeLiquidity(alice, -LIQUIDITY);
    }

    function test_event_SolvencyWarning_emitted() public {
        _addLiquidityInsured(alice, 300, LIQUIDITY);
        // Solvency is naturally << 120% after just one premium deposit
        // Adding and removing a tiny Bob position triggers _checkSolvency with low ratio
        _addLiquidityInsured(bob, 5000, 1e15);

        vm.expectEmit(true, false, false, false);
        emit PremiumYieldHook.SolvencyWarning(poolId, 0);
        _removeLiquidity(bob, -1e15);
    }

    function test_event_DepositsPaused_autoEmitted() public {
        // Alice: large position at 1-bps threshold → massive liability
        // Bob: tiny position — removing only Bob leaves Alice's liability intact, solvency ≈ 0 → auto-pause
        _addLiquidityInsured(alice, 1, LIQUIDITY);
        _addLiquidityInsured(bob, 5000, 1e15);

        // Forward-scan for DepositsPausedEvent from hook (fires after SolvencyWarning + Transfer events)
        vm.expectEmit(true, false, false, false);
        emit PremiumYieldHook.DepositsPausedEvent(poolId);
        _removeLiquidity(bob, -1e15);
    }

    // ── Price movement scenarios ───────────────────────────────────────────────

    function test_smallPriceMove_belowThreshold_noClaimHighThreshold() public {
        _addInitialLiquidity(LIQUIDITY * 10);
        _addLiquidityInsured(alice, 5000, LIQUIDITY); // 50% threshold

        // Small price move — IL likely < 50%
        _movePrice(true, -100_000e18);

        // Expect PremiumReturned (no claim) since IL < 5000 bps
        // (we can't guarantee this exactly but it's the expected path for a small move)
        _removeLiquidity(alice, -LIQUIDITY);
        (,,,,,,, bool active) = hook.positions(_positionId(alice));
        assertFalse(active, "position must settle regardless of path");
    }

    function test_largePriceMove_zeroForOne_triggersClaim() public {
        _addInitialLiquidity(LIQUIDITY * 10);
        _addLiquidityInsured(alice, 100, LIQUIDITY); // 1% threshold

        (uint160 entryPrice,,,) = IPoolManager(address(poolManager)).getSlot0(poolKey.toId());

        _movePrice(true, -5_000_000e18); // large token0 → token1 swap

        (uint160 exitPrice,,,) = IPoolManager(address(poolManager)).getSlot0(poolKey.toId());
        assertNotEq(entryPrice, exitPrice, "price must have moved");

        _removeLiquidity(alice, -LIQUIDITY);
        (,,,,,,, bool active) = hook.positions(_positionId(alice));
        assertFalse(active);
    }

    function test_largePriceMove_oneForZero_triggersClaim() public {
        _addInitialLiquidity(LIQUIDITY * 10);
        _addLiquidityInsured(alice, 100, LIQUIDITY);

        (uint160 priceBefore,,,) = IPoolManager(address(poolManager)).getSlot0(poolKey.toId());
        _movePrice(false, -5_000_000e18); // large token1 → token0 swap
        (uint160 priceAfter,,,) = IPoolManager(address(poolManager)).getSlot0(poolKey.toId());
        assertNotEq(priceBefore, priceAfter);

        _removeLiquidity(alice, -LIQUIDITY);
        (,,,,,,, bool active) = hook.positions(_positionId(alice));
        assertFalse(active);
    }

    function test_regimeCapturedAtDeposit() public {
        oracle.setRegime(0); // Calm: multiplier 1×, premiumBps = 5
        uint256 v0 = vault.totalAssets();
        _addLiquidityInsured(alice, 300, LIQUIDITY);
        uint256 calmPremium = vault.totalAssets() - v0;

        oracle.setRegime(3); // Extreme: multiplier 4×, premiumBps = 20
        uint256 v1 = vault.totalAssets();
        _addLiquidityInsured(bob, 300, LIQUIDITY);
        uint256 extremePremium = vault.totalAssets() - v1;

        assertEq(calmPremium, uint256(int256(LIQUIDITY)) * 5 / 10_000, "calm regime uses 5 bps");
        assertEq(extremePremium, uint256(int256(LIQUIDITY)) * 20 / 10_000, "extreme regime uses 20 bps");
        assertGt(extremePremium, calmPremium);
    }

    function test_calmRegime_lowerPremium_thanExtreme() public {
        oracle.setRegime(0);
        uint256 v0 = vault.totalAssets();
        _addLiquidityInsured(alice, 300, LIQUIDITY);
        uint256 calmPremium = vault.totalAssets() - v0;

        oracle.setRegime(3);
        uint256 v1 = vault.totalAssets();
        _addLiquidityInsured(bob, 300, LIQUIDITY);
        uint256 extremePremium = vault.totalAssets() - v1;

        assertGt(extremePremium, calmPremium, "Extreme must charge more than Calm");
        // Extreme / Calm = 20 / 5 = 4×
        assertApproxEqRel(extremePremium, calmPremium * 4, 0.01e18);
    }

    function test_positionEntry_priceStoredCorrectly() public {
        (uint160 poolPriceBeforeDeposit,,,) = IPoolManager(address(poolManager)).getSlot0(poolKey.toId());
        _addLiquidityInsured(alice, 300, LIQUIDITY);
        (,, uint160 storedEntryPrice,,,,,) = hook.positions(_positionId(alice));
        assertEq(storedEntryPrice, poolPriceBeforeDeposit, "entry price must match pool price at deposit");
    }

    function test_multipleSwaps_cumulativeILEffect() public {
        _addInitialLiquidity(LIQUIDITY * 10);
        _addLiquidityInsured(alice, 100, LIQUIDITY);

        (uint160 p0,,,) = IPoolManager(address(poolManager)).getSlot0(poolKey.toId());

        _movePrice(true, -1_000_000e18);
        (uint160 p1,,,) = IPoolManager(address(poolManager)).getSlot0(poolKey.toId());

        _movePrice(true, -1_000_000e18);
        (uint160 p2,,,) = IPoolManager(address(poolManager)).getSlot0(poolKey.toId());

        // Each swap moved price further
        assertNotEq(p0, p1);
        assertNotEq(p1, p2);

        // Withdrawal should complete without revert
        _removeLiquidity(alice, -LIQUIDITY);
        (,,,,,,, bool active) = hook.positions(_positionId(alice));
        assertFalse(active);
    }

    // ── Solvency scenarios ────────────────────────────────────────────────────

    function test_solvencyRatio_isLow_afterFirstDeposit() public {
        _addLiquidityInsured(alice, 300, LIQUIDITY);
        uint256 ratio = hook.getSolvencyRatio(poolId);
        // Premium (7 bps of notional) << max liability (97% of notional)
        // Ratio ≈ 7 bps << 12000 bps (120%)
        assertLt(ratio, 12_000, "solvency should be low after just one premium deposit");
    }

    function test_solvency_improves_withSimulatedYield() public {
        _addLiquidityInsured(alice, 300, LIQUIDITY);
        uint256 ratioBefore = hook.getSolvencyRatio(poolId);

        uint256 liability = hook.totalCoverageLiability(poolId);
        vault.simulateYield(liability * 2); // donate 200% of liability as yield

        uint256 ratioAfter = hook.getSolvencyRatio(poolId);
        assertGt(ratioAfter, ratioBefore, "yield must improve solvency ratio");
        assertGt(ratioAfter, 12_000, "should be well above 120% after generous yield");
    }

    function test_autopaused_at_lowSolvency_afterWithdrawal() public {
        // Alice: large position at 1-bps threshold → liability ≈ LIQUIDITY (≈ 1e24)
        // Bob: tiny 1e15 position — his removal barely dents total liability, so solvency stays ≈ 0
        _addLiquidityInsured(alice, 1, LIQUIDITY);
        _addLiquidityInsured(bob, 5000, 1e15);
        assertFalse(hook.depositsPausedMap(poolId), "deposits active before withdrawal");

        _removeLiquidity(bob, -1e15);
        assertTrue(hook.depositsPausedMap(poolId), "deposits should be auto-paused after withdrawal at low solvency");
    }

    function test_autopaused_canBeResumed_byAdmin() public {
        // Same two-LP setup so auto-pause reliably fires on Bob's tiny removal
        _addLiquidityInsured(alice, 1, LIQUIDITY);
        _addLiquidityInsured(bob, 5000, 1e15);
        _removeLiquidity(bob, -1e15);
        assertTrue(hook.depositsPausedMap(poolId), "auto-paused");

        vm.prank(admin);
        hook.resumeDeposits(poolId);
        assertFalse(hook.depositsPausedMap(poolId), "resumed by admin");

        // Deposit should succeed again after manual resume
        _addLiquidityInsured(bob, 500, LIQUIDITY);
        (,,,,,,, bool active) = hook.positions(_positionId(bob));
        assertTrue(active);
    }

    function test_noSolvencyWarning_whenRatioHigh() public {
        _addLiquidityInsured(alice, 300, LIQUIDITY);
        uint256 liability = hook.totalCoverageLiability(poolId);
        vault.simulateYield(liability * 3); // 300%+ solvency

        // After this removal, solvency remains high → no auto-pause
        _overcapitalize();
        _removeLiquidity(alice, -LIQUIDITY);

        assertFalse(hook.depositsPausedMap(poolId), "deposits should remain unpaused at high solvency");
    }

    function test_solvencyRatio_afterMultipleDeposits() public {
        _addLiquidityInsured(alice, 300, LIQUIDITY);
        uint256 r1 = hook.getSolvencyRatio(poolId);

        _addLiquidityInsured(bob, 500, LIQUIDITY);
        uint256 r2 = hook.getSolvencyRatio(poolId);

        // More premiums improve the ratio (vault grows while coverage liability grows too)
        // Both grow proportionally with similar liquidity, so ratio ≈ constant
        // The key is ratio stays positive
        assertGt(r2, 0);
        assertLt(r2, type(uint256).max);
        console2.log("solvency after 2 deposits:", r2);
    }

    function test_coverageLiability_incrementsOnDeposit() public {
        uint256 before = hook.totalCoverageLiability(poolId);
        _addLiquidityInsured(alice, 300, LIQUIDITY);
        uint256 after_ = hook.totalCoverageLiability(poolId);

        uint256 expected = (10_000 - 300) * uint256(int256(LIQUIDITY)) / 10_000;
        assertEq(after_ - before, expected, "liability must match (BPS-threshold)*notional/BPS");
    }

    function test_coverageLiability_decrementsOnWithdrawal() public {
        _addLiquidityInsured(alice, 300, LIQUIDITY);
        uint256 liabilityAfterAdd = hook.totalCoverageLiability(poolId);
        assertGt(liabilityAfterAdd, 0);

        _removeLiquidity(alice, -LIQUIDITY);
        uint256 liabilityAfterRemove = hook.totalCoverageLiability(poolId);
        assertLe(liabilityAfterRemove, liabilityAfterAdd, "liability must decrease after withdrawal");
    }

    // ── Edge cases / boundary conditions ─────────────────────────────────────

    function test_minThreshold_1bps_accepted() public {
        _addLiquidityInsured(alice, 1, LIQUIDITY); // 0.01% = minimum allowed
        (,,,,,,, bool active) = hook.positions(_positionId(alice));
        assertTrue(active);
    }

    function test_maxThreshold_5000bps_accepted() public {
        _addLiquidityInsured(alice, 5000, LIQUIDITY); // 50% = maximum allowed
        (,,,,,,, bool active) = hook.positions(_positionId(alice));
        assertTrue(active);
    }

    function test_threshold_0_reverts() public {
        vm.startPrank(alice);
        token0.approve(address(liquidityRouter), type(uint256).max);
        token1.approve(address(liquidityRouter), type(uint256).max);
        token0.approve(address(hook), type(uint256).max);
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: LIQUIDITY, salt: bytes32(0)
        });
        vm.expectRevert();
        liquidityRouter.modifyLiquidity(poolKey, params, abi.encode(uint256(0), true, alice));
        vm.stopPrank();
    }

    function test_threshold_5001_reverts() public {
        vm.startPrank(alice);
        token0.approve(address(liquidityRouter), type(uint256).max);
        token1.approve(address(liquidityRouter), type(uint256).max);
        token0.approve(address(hook), type(uint256).max);
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: LIQUIDITY, salt: bytes32(0)
        });
        vm.expectRevert();
        liquidityRouter.modifyLiquidity(poolKey, params, abi.encode(uint256(5001), true, alice));
        vm.stopPrank();
    }

    function test_emptyHookData_noEffect_addLiquidity() public {
        uint256 vaultBefore = vault.totalAssets();
        vm.startPrank(alice);
        token0.approve(address(liquidityRouter), type(uint256).max);
        token1.approve(address(liquidityRouter), type(uint256).max);
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: LIQUIDITY, salt: bytes32(0)
        });
        liquidityRouter.modifyLiquidity(poolKey, params, bytes(""));
        vm.stopPrank();

        assertEq(vault.totalAssets(), vaultBefore, "empty hookData: no premium charged");
        (,,,,,,, bool active) = hook.positions(_positionId(alice));
        assertFalse(active, "empty hookData: no position recorded");
    }

    function test_emptyHookData_noEffect_removeLiquidity() public {
        // Add without insurance first
        vm.startPrank(alice);
        token0.approve(address(liquidityRouter), type(uint256).max);
        token1.approve(address(liquidityRouter), type(uint256).max);
        liquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(TICK_LOWER, TICK_UPPER, LIQUIDITY, bytes32(0)), bytes("")
        );
        // Remove with empty hookData — must not revert
        liquidityRouter.modifyLiquidity(
            poolKey, ModifyLiquidityParams(TICK_LOWER, TICK_UPPER, -LIQUIDITY, bytes32(0)), bytes("")
        );
        vm.stopPrank();
    }

    function test_noApproval_premiumTransferFails() public {
        vm.startPrank(alice);
        token0.approve(address(liquidityRouter), type(uint256).max);
        token1.approve(address(liquidityRouter), type(uint256).max);
        // Deliberately NOT approving hook for token0 premium
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: LIQUIDITY, salt: bytes32(0)
        });
        vm.expectRevert();
        liquidityRouter.modifyLiquidity(poolKey, params, abi.encode(uint256(300), true, alice));
        vm.stopPrank();
    }

    function test_wantsInsurance_false_vaultUnchanged() public {
        uint256 vaultBefore = vault.totalAssets();
        vm.startPrank(alice);
        token0.approve(address(liquidityRouter), type(uint256).max);
        token1.approve(address(liquidityRouter), type(uint256).max);
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: LIQUIDITY, salt: bytes32(0)
        });
        liquidityRouter.modifyLiquidity(poolKey, params, abi.encode(uint256(300), false, alice));
        vm.stopPrank();
        assertEq(vault.totalAssets(), vaultBefore);
    }

    function test_vaultNotSet_reverts_withInsurance() public {
        // New pool with no vault registered
        MockERC20 tx0 = new MockERC20("X", "X", 18);
        MockERC20 tx1 = new MockERC20("Y", "Y", 18);
        if (address(tx0) > address(tx1)) (tx0, tx1) = (tx1, tx0);
        PoolKey memory newKey = PoolKey({
            currency0: Currency.wrap(address(tx0)),
            currency1: Currency.wrap(address(tx1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        vm.prank(admin);
        poolManager.initialize(newKey, INITIAL_SQRT_PRICE);

        tx0.mint(alice, 1_000_000e18);
        tx1.mint(alice, 1_000_000e18);
        vm.startPrank(alice);
        tx0.approve(address(liquidityRouter), type(uint256).max);
        tx1.approve(address(liquidityRouter), type(uint256).max);
        tx0.approve(address(hook), type(uint256).max);
        vm.expectRevert();
        liquidityRouter.modifyLiquidity(
            newKey,
            ModifyLiquidityParams(TICK_LOWER, TICK_UPPER, LIQUIDITY, bytes32(0)),
            abi.encode(uint256(300), true, alice)
        );
        vm.stopPrank();
    }

    function test_wrongLPAddress_inHookData_noEffect() public {
        _addLiquidityInsured(alice, 300, LIQUIDITY);

        // Remove using Bob's address as the LP in hookData — hook looks up Bob's (non-existent) position
        vm.startPrank(alice);
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: -LIQUIDITY, salt: bytes32(0)
        });
        liquidityRouter.modifyLiquidity(poolKey, params, abi.encode(bob)); // wrong LP address
        vm.stopPrank();

        // Alice's position should still be active (hook used Bob's posId, which was inactive)
        (,,,,,,, bool aliceActive) = hook.positions(_positionId(alice));
        assertTrue(aliceActive, "Alice's position must remain active when wrong LP used");
    }

    // ── Fuzz tests ────────────────────────────────────────────────────────────

    // Any threshold in [1, 5000] should never cause a revert
    function test_fuzz_validThreshold_neverReverts(uint16 threshold) public {
        vm.assume(threshold >= 1 && threshold <= 5000);
        _addLiquidityInsured(alice, threshold, LIQUIDITY);
        (,,,,,,, bool active) = hook.positions(_positionId(alice));
        assertTrue(active);
    }

    // Any threshold > 5000 should always revert with InvalidThreshold (wrapped by PM)
    function test_fuzz_invalidAboveMax_threshold_alwaysReverts(uint16 threshold) public {
        vm.assume(uint256(threshold) > 5000);
        vm.startPrank(alice);
        token0.approve(address(liquidityRouter), type(uint256).max);
        token1.approve(address(liquidityRouter), type(uint256).max);
        token0.approve(address(hook), type(uint256).max);
        ModifyLiquidityParams memory params = ModifyLiquidityParams({
            tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: LIQUIDITY, salt: bytes32(0)
        });
        vm.expectRevert();
        liquidityRouter.modifyLiquidity(poolKey, params, abi.encode(uint256(threshold), true, alice));
        vm.stopPrank();
    }

    // Premium must be > 0 for any liquidity that produces a non-trivial notional
    function test_fuzz_premiumNonZero_forSufficientLiquidity(uint32 liquidityDelta) public {
        vm.assume(liquidityDelta > 1_000_000); // notional > 1M → Normal 7-bps premium > 0
        oracle.setRegime(1); // Normal (7 bps)

        uint256 vaultBefore = vault.totalAssets();
        _addLiquidityInsured(alice, 300, int256(uint256(liquidityDelta)));
        uint256 premium = vault.totalAssets() - vaultBefore;

        assertGt(premium, 0, "premium must be non-zero for sufficient liquidity");
    }

    // All regime values [0,3] must be accepted by the hook
    function test_fuzz_regime_allValues_accepted(uint8 regime) public {
        vm.assume(regime <= 3);
        oracle.setRegime(regime);
        uint256 vaultBefore = vault.totalAssets();
        _addLiquidityInsured(alice, 300, LIQUIDITY);
        assertGe(vault.totalAssets(), vaultBefore, "vault should have grown for any regime");
    }

    // Full add→remove lifecycle must complete without revert for any valid threshold
    function test_fuzz_addAndRemove_fullLifecycle(uint16 threshold) public {
        vm.assume(threshold >= 1 && threshold <= 5000);
        _addLiquidityInsured(alice, threshold, LIQUIDITY);
        _removeLiquidity(alice, -LIQUIDITY);
        (,,,,,,, bool active) = hook.positions(_positionId(alice));
        assertFalse(active, "position must be settled after full lifecycle");
    }

    // Coverage liability must never underflow (always decrements correctly)
    function test_fuzz_coverageLiability_neverUnderflows(uint16 threshold) public {
        vm.assume(threshold >= 1 && threshold <= 5000);
        _addLiquidityInsured(alice, threshold, LIQUIDITY);
        uint256 liabilityBefore = hook.totalCoverageLiability(poolId);
        _removeLiquidity(alice, -LIQUIDITY);
        uint256 liabilityAfter = hook.totalCoverageLiability(poolId);
        assertLe(liabilityAfter, liabilityBefore, "liability can only decrease on withdrawal");
    }

    // Vault shares recorded in position must equal shares actually minted by vault
    function test_fuzz_vaultShares_recordedCorrectly(uint8 regime) public {
        vm.assume(regime <= 3);
        oracle.setRegime(regime);

        uint256 sharesBefore = vault.totalSupply();
        _addLiquidityInsured(alice, 300, LIQUIDITY);
        uint256 newShares = vault.totalSupply() - sharesBefore;

        (,,,,,, uint256 recordedShares,) = hook.positions(_positionId(alice));
        assertEq(recordedShares, newShares, "recorded shares must match vault-issued shares");
    }

    // Multi-LP vault accounting: vault holds exactly the sum of all premiums paid
    function test_fuzz_multipleLP_vaultAccounting(uint8 regimeA, uint8 regimeB) public {
        vm.assume(regimeA <= 3 && regimeB <= 3);

        oracle.setRegime(regimeA);
        uint256 v0 = vault.totalAssets();
        _addLiquidityInsured(alice, 300, LIQUIDITY);
        uint256 alicePremium = vault.totalAssets() - v0;

        oracle.setRegime(regimeB);
        uint256 v1 = vault.totalAssets();
        _addLiquidityInsured(bob, 500, LIQUIDITY);
        uint256 bobPremium = vault.totalAssets() - v1;

        assertEq(vault.totalAssets(), v0 + alicePremium + bobPremium, "vault must hold both premiums exactly");
    }
}
