// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta, toBalanceDelta, BalanceDeltaLibrary} from "v4-core/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {FixedPoint96} from "v4-core/libraries/FixedPoint96.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import {SafeCast} from "v4-core/libraries/SafeCast.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

import {IVolatilityOracle} from "./interfaces/IVolatilityOracle.sol";
import {ILCalculator} from "./libraries/ILCalculator.sol";

/// @title PremiumYieldHook
/// @notice Uniswap v4 hook providing IL insurance for LPs while earning yield on collected premiums.
///
/// Lifecycle:
///   beforeAddLiquidity  — collects a volatility-scaled premium from the LP, deposits it
///                          into an ERC4626 vault, and records the insured position.
///   afterRemoveLiquidity — calculates realized IL at withdrawal; if IL > LP's threshold,
///                          pays out the excess from vault proceeds; otherwise returns the
///                          premium + accrued vault yield to the LP.
///
/// Hook address encoding (lower 14 bits must match):
///   BEFORE_ADD_LIQUIDITY_FLAG                 (1 << 11 = 0x800)
///   AFTER_REMOVE_LIQUIDITY_FLAG               (1 << 8  = 0x100)
///   AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG (1 << 0  = 0x001)
///   Required mask: 0x901
contract PremiumYieldHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using StateLibrary for IPoolManager;
    using SafeCast for uint256;
    using SafeCast for int256;

    // ── Errors ────────────────────────────────────────────────────────────
    error NotPoolManager();
    error NotOwner();
    error VaultNotSet();
    error DepositsPaused();
    error InvalidThreshold();
    error HookNotImplemented();

    // ── Events ────────────────────────────────────────────────────────────
    event PremiumCollected(
        bytes32 indexed positionId,
        address indexed lp,
        uint256 premiumAmount,
        uint256 vaultShares,
        uint8 volatilityRegime
    );
    event ClaimProcessed(
        bytes32 indexed positionId, address indexed lp, uint256 ilBps, uint256 thresholdBps, uint256 payoutAmount
    );
    event PremiumReturned(bytes32 indexed positionId, address indexed lp, uint256 premiumReturned, uint256 yieldEarned);
    event SolvencyWarning(bytes32 indexed poolId, uint256 solvencyRatioBps);
    event PoolVaultSet(bytes32 indexed poolId, address vault);
    event DepositsPausedEvent(bytes32 indexed poolId);
    event DepositsResumedEvent(bytes32 indexed poolId);

    // ── Structs ───────────────────────────────────────────────────────────
    struct LPPosition {
        address owner;
        uint128 liquidityAdded;
        uint160 entryPrice; // sqrtPriceX96 at deposit
        uint256 entryTimestamp;
        uint256 coverageThresholdBps; // IL% above which payout fires (1–5000 bps)
        uint256 premiumPaid; // currency0 amount
        uint256 vaultShares; // ERC4626 shares held on LP's behalf
        bool active;
    }

    // ── Constants ─────────────────────────────────────────────────────────
    uint256 public constant BASE_PREMIUM_BPS = 5; // 0.05% base rate
    uint256 public constant MIN_SOLVENCY_RATIO_BPS = 11_000; // 110% — auto-pause threshold
    uint256 public constant SOLVENCY_WARNING_BPS = 12_000; // 120% — warning threshold
    uint256 public constant MIN_COVERAGE_BPS = 1; // 0.01% minimum threshold
    uint256 public constant MAX_COVERAGE_BPS = 5_000; // 50% maximum threshold
    uint256 public constant BPS = 10_000;

    // ── Immutables ────────────────────────────────────────────────────────
    IPoolManager public immutable poolManager;
    IVolatilityOracle public immutable volOracle;
    address public immutable owner;

    // ── Storage ───────────────────────────────────────────────────────────
    // positionId = keccak256(owner, poolId, tickLower, tickUpper, salt)
    mapping(bytes32 => LPPosition) public positions;

    // poolId => total outstanding max coverage liability (in currency0 units)
    mapping(bytes32 => uint256) public totalCoverageLiability;

    // poolId => ERC4626 vault address
    mapping(bytes32 => address) public poolVault;

    // poolId => deposits paused flag (auto-set at 110% solvency, manual override available)
    mapping(bytes32 => bool) public depositsPausedMap;

    // ── Constructor ───────────────────────────────────────────────────────
    constructor(IPoolManager _poolManager, IVolatilityOracle _volOracle) {
        poolManager = _poolManager;
        volOracle = _volOracle;
        owner = msg.sender;
        // Note: Hooks.validateHookPermissions is intentionally NOT called here.
        // The impl bytecode is etched to a pre-mined address (via vm.etch in tests,
        // or CREATE2 in production) that already carries the correct flag bits.
        // The PoolManager enforces address-bit validity on pool initialization.
    }

    // ── Modifiers ─────────────────────────────────────────────────────────
    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ── Admin ─────────────────────────────────────────────────────────────

    /// @notice Register an ERC4626 vault for a pool (must be set before LPs can buy insurance)
    function setPoolVault(bytes32 pid, address vault) external onlyOwner {
        poolVault[pid] = vault;
        emit PoolVaultSet(pid, vault);
    }

    function pauseDeposits(bytes32 pid) external onlyOwner {
        depositsPausedMap[pid] = true;
        emit DepositsPausedEvent(pid);
    }

    function resumeDeposits(bytes32 pid) external onlyOwner {
        depositsPausedMap[pid] = false;
        emit DepositsResumedEvent(pid);
    }

    // ── Hook Permissions ──────────────────────────────────────────────────

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: true
        });
    }

    // ── beforeAddLiquidity ────────────────────────────────────────────────

    /// @inheritdoc IHooks
    /// @dev hookData encoding: abi.encode(uint256 coverageThresholdBps, bool wantsInsurance, address lp)
    ///      `lp` is the actual LP wallet (msg.sender to the router) that has pre-approved this hook
    ///      for the premium amount. This is needed because `sender` is the router contract, not the LP.
    function beforeAddLiquidity(
        address, /* sender — the router; we use the LP address from hookData instead */
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4) {
        if (hookData.length == 0) return IHooks.beforeAddLiquidity.selector;

        (uint256 coverageThresholdBps, bool wantsInsurance, address lp) = abi.decode(hookData, (uint256, bool, address));
        if (!wantsInsurance) return IHooks.beforeAddLiquidity.selector;

        if (coverageThresholdBps < MIN_COVERAGE_BPS || coverageThresholdBps > MAX_COVERAGE_BPS) {
            revert InvalidThreshold();
        }

        bytes32 pid = PoolId.unwrap(key.toId());
        address vault = poolVault[pid];
        if (vault == address(0)) revert VaultNotSet();
        if (depositsPausedMap[pid]) revert DepositsPaused();

        // ── Premium calculation ───────────────────────────────────────────
        uint8 regime = _safeGetRegime(key);
        uint256 multiplier = _getMultiplier(regime);

        // Notional in currency0 units: liquidity * Q96 / sqrtPrice
        uint256 notional = _estimateNotional(params, key);

        // premiumBps = BASE * multiplier / 100  (multiplier is ×100-scaled: 100=1.0×, 400=4.0×)
        uint256 premiumBps = (BASE_PREMIUM_BPS * multiplier) / 100;
        uint256 premiumAmount = (notional * premiumBps) / BPS;

        if (premiumAmount == 0) return IHooks.beforeAddLiquidity.selector;

        // ── Collect premium from LP ───────────────────────────────────────
        // LP must pre-approve this hook for currency0 before calling modifyLiquidity
        IERC20 token0 = IERC20(Currency.unwrap(key.currency0));
        token0.transferFrom(lp, address(this), premiumAmount);

        // ── Deploy to vault ───────────────────────────────────────────────
        token0.approve(vault, premiumAmount);
        uint256 sharesReceived = IERC4626(vault).deposit(premiumAmount, address(this));

        // ── Record position ───────────────────────────────────────────────
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        bytes32 posId = _positionId(lp, key, params);

        positions[posId] = LPPosition({
            owner: lp,
            liquidityAdded: uint128(
                uint256(params.liquidityDelta > 0 ? params.liquidityDelta : -params.liquidityDelta)
            ),
            entryPrice: sqrtPriceX96,
            entryTimestamp: block.timestamp,
            coverageThresholdBps: coverageThresholdBps,
            premiumPaid: premiumAmount,
            vaultShares: sharesReceived,
            active: true
        });

        // Track maximum possible coverage liability for solvency monitoring
        totalCoverageLiability[pid] += _maxCoverageAmount(notional, coverageThresholdBps);

        emit PremiumCollected(posId, lp, premiumAmount, sharesReceived, regime);
        return IHooks.beforeAddLiquidity.selector;
    }

    // ── afterRemoveLiquidity ──────────────────────────────────────────────

    /// @inheritdoc IHooks
    /// @dev Injects the insurance payout (or premium refund + yield) into the LP's settlement
    ///      by settling tokens with the PoolManager then returning a negative BalanceDelta.
    ///
    ///      Settlement pattern for giving tokens to LP:
    ///        sync(currency0) → transfer(token0, poolManager, amount) → settle()
    ///        → return toBalanceDelta(-amount, 0)
    ///      The hook's positive delta from settle() is cancelled by the returned negative delta,
    ///      netting to zero for the hook while adding +amount to the LP's callerDelta.
    /// @dev hookData for removal: abi.encode(address lp) — the LP wallet whose position to settle.
    ///      Omit hookData (or pass empty bytes) if the LP has no insured position.
    function afterRemoveLiquidity(
        address, /* sender — the router; LP address comes from hookData */
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta, /* feesAccrued */
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        if (hookData.length < 32) return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        address lp = abi.decode(hookData, (address));
        bytes32 posId = _positionId(lp, key, params);
        LPPosition storage pos = positions[posId];

        if (!pos.active) return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);

        bytes32 pid = PoolId.unwrap(key.toId());
        address vault = poolVault[pid];

        // ── Read position state before any external calls (CEI) ──────────
        uint256 premiumPaid = pos.premiumPaid;
        uint256 vaultShares = pos.vaultShares;
        uint256 coverageThresholdBps = pos.coverageThresholdBps;
        uint160 entryPrice = pos.entryPrice;
        address lpOwner = pos.owner;
        uint256 notional = _getPositionValue(delta);
        bytes32 cachedPosId = posId;

        // Mark inactive before external calls
        pos.active = false;

        // ── Redeem vault shares → hook receives currency0 ─────────────────
        uint256 vaultRedemptionValue = IERC4626(vault).redeem(vaultShares, address(this), address(this));

        // ── IL calculation ────────────────────────────────────────────────
        (uint160 exitPrice,,,) = poolManager.getSlot0(key.toId());
        uint256 ilBps = ILCalculator.calculate(uint256(entryPrice), uint256(exitPrice));

        // ── Determine payout or refund amount ─────────────────────────────
        uint256 transferAmount;
        bool isClaim = ilBps > coverageThresholdBps;

        if (isClaim) {
            uint256 payoutAmount = _calculatePayout(ilBps, coverageThresholdBps, notional);
            transferAmount = payoutAmount > vaultRedemptionValue ? vaultRedemptionValue : payoutAmount;
            uint256 yieldEarned = vaultRedemptionValue > premiumPaid ? vaultRedemptionValue - premiumPaid : 0;
            emit ClaimProcessed(cachedPosId, lpOwner, ilBps, coverageThresholdBps, transferAmount);
            (yieldEarned); // silence unused variable warning
            // Surplus (vaultRedemptionValue - transferAmount) remains in hook as fund reserves
        } else {
            // Return full premium + yield to LP
            transferAmount = vaultRedemptionValue;
            uint256 yieldEarned = vaultRedemptionValue > premiumPaid ? vaultRedemptionValue - premiumPaid : 0;
            emit PremiumReturned(cachedPosId, lpOwner, premiumPaid, yieldEarned);
        }

        // ── Update coverage liability ─────────────────────────────────────
        uint256 liabilityReduction = _maxCoverageAmount(notional, coverageThresholdBps);
        if (totalCoverageLiability[pid] >= liabilityReduction) {
            unchecked {
                totalCoverageLiability[pid] -= liabilityReduction;
            }
        } else {
            totalCoverageLiability[pid] = 0;
        }

        // ── Solvency check ────────────────────────────────────────────────
        _checkSolvency(pid, vault);

        // ── Inject payout into LP's delta ─────────────────────────────────
        if (transferAmount == 0) {
            return (IHooks.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
        }

        IERC20 token0 = IERC20(Currency.unwrap(key.currency0));
        // 1. Sync so PoolManager knows the current token0 balance
        poolManager.sync(key.currency0);
        // 2. Transfer token0 to PoolManager
        token0.transfer(address(poolManager), transferAmount);
        // 3. Settle — credits hook's delta with +transferAmount
        poolManager.settle();
        // 4. Return negative delta — hook's credit is consumed, LP's callerDelta gains +transferAmount
        return (IHooks.afterRemoveLiquidity.selector, toBalanceDelta(-int128(int256(transferAmount)), 0));
    }

    // ── View helpers ──────────────────────────────────────────────────────

    /// @notice Current solvency ratio for a pool (vault TVL / coverage liability) in bps
    function getSolvencyRatio(bytes32 pid) external view returns (uint256) {
        return _getSolvencyRatio(pid, poolVault[pid]);
    }

    // ── IHooks stubs (unused hook callbacks) ──────────────────────────────
    // Not called by PoolManager (flags not set); satisfy the interface only.

    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure override returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        external
        pure
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert HookNotImplemented();
    }

    function afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        pure
        override
        returns (bytes4, int128)
    {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        pure
        override
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    // ── Internal helpers ──────────────────────────────────────────────────

    function _positionId(address lpOwner, PoolKey calldata key, ModifyLiquidityParams calldata params)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(lpOwner, key.toId(), params.tickLower, params.tickUpper, params.salt));
    }

    /// @dev notional ≈ liquidity * Q96 / sqrtPriceX96 in currency0 terms
    function _estimateNotional(ModifyLiquidityParams calldata params, PoolKey calldata key)
        internal
        view
        returns (uint256)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        if (sqrtPriceX96 == 0) return 0;
        uint256 liquidity = params.liquidityDelta > 0
            ? uint256(int256(params.liquidityDelta))
            : uint256(-int256(params.liquidityDelta));
        return FullMath.mulDiv(liquidity, FixedPoint96.Q96, sqrtPriceX96);
    }

    /// @dev Sum of absolute token amounts from the removal delta as a proxy for position value
    function _getPositionValue(BalanceDelta d) internal pure returns (uint256) {
        int128 a0 = d.amount0();
        int128 a1 = d.amount1();
        uint256 v0 = a0 >= 0 ? uint256(int256(a0)) : uint256(int256(-a0));
        uint256 v1 = a1 >= 0 ? uint256(int256(a1)) : uint256(int256(-a1));
        return v0 + v1;
    }

    /// @dev Payout = (ilBps - thresholdBps) * positionValue / BPS
    function _calculatePayout(uint256 ilBps, uint256 thresholdBps, uint256 positionValue)
        internal
        pure
        returns (uint256)
    {
        if (ilBps <= thresholdBps) return 0;
        return FullMath.mulDiv(ilBps - thresholdBps, positionValue, BPS);
    }

    /// @dev Max coverage = (BPS - thresholdBps) * notional / BPS
    function _maxCoverageAmount(uint256 notional, uint256 thresholdBps) internal pure returns (uint256) {
        if (thresholdBps >= BPS) return 0;
        return FullMath.mulDiv(BPS - thresholdBps, notional, BPS);
    }

    function _getMultiplier(uint8 regime) internal pure returns (uint256) {
        if (regime == 0) return 100; // 1.0×
        if (regime == 1) return 150; // 1.5×
        if (regime == 2) return 250; // 2.5×
        return 400; //                  4.0×
    }

    /// @dev Wraps oracle call with try/catch — falls back to Normal regime on failure (FR-5)
    function _safeGetRegime(PoolKey calldata key) internal view returns (uint8) {
        try volOracle.getCurrentRegime(Currency.unwrap(key.currency0), Currency.unwrap(key.currency1)) returns (
            uint8 regime
        ) {
            return regime;
        } catch {
            return 1; // Normal regime fallback
        }
    }

    function _getSolvencyRatio(bytes32 pid, address vault) internal view returns (uint256) {
        if (vault == address(0)) return type(uint256).max;
        uint256 liability = totalCoverageLiability[pid];
        if (liability == 0) return type(uint256).max;
        uint256 vaultValue = IERC4626(vault).totalAssets();
        return FullMath.mulDiv(vaultValue, BPS, liability);
    }

    function _checkSolvency(bytes32 pid, address vault) internal {
        uint256 ratio = _getSolvencyRatio(pid, vault);
        if (ratio == type(uint256).max) return;

        if (ratio < SOLVENCY_WARNING_BPS) {
            emit SolvencyWarning(pid, ratio);
        }

        if (ratio < MIN_SOLVENCY_RATIO_BPS && !depositsPausedMap[pid]) {
            depositsPausedMap[pid] = true;
            emit DepositsPausedEvent(pid);
        }
    }
}
