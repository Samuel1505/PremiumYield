# PremiumYield Hook
## IL Insurance Fund Where the Premiums Earn Yield

> **UHI9 Hookathon Submission Guide**
> Uniswap Hook Incubator | Cohort 9 | Hookathon: May 25, 2026

---

## Table of Contents

1. [Product Requirements Document (PRD)](#1-product-requirements-document)
2. [Deep Technical Architecture](#2-deep-technical-architecture)
3. [Build Guide](#3-build-guide)

---

# 1. Product Requirements Document

## 1.1 Problem Statement

Impermanent loss (IL) is the primary reason sophisticated capital refuses to provide liquidity on Uniswap. Existing solutions are reactive — they adjust fees or rebalance positions *after* IL has already occurred. No Uniswap v4 hook has ever built a **structurally capitalized, yield-bearing insurance fund** that protects LPs from IL while making money on the premiums in between.

Most importantly: every prior "insurance" design treats the protection fund as a dead cost center. PremiumYield treats it as an **earning asset**.

## 1.2 Target Users

| User Segment | Problem They Have | How PremiumYield Solves It |
|---|---|---|
| Passive LPs | IL destroys returns unpredictably | Guaranteed IL coverage above threshold |
| Yield-seeking LPs | Fee APY is inconsistent | Premium vault yield supplements fee income |
| Protocols deploying liquidity | Need predictable treasury LP returns | Fixed insurance + yield creates predictable floor |
| Insurance underwriters (future) | No DeFi-native LP insurance market | Fund structure enables underwriter participation |

## 1.3 Core Value Proposition

> *"You pay a small premium on entry. If IL destroys your position, you're covered. If it doesn't, you earn yield on your own insurance premium. Either way, you win."*

This is structurally different from all prior hooks:

- **Prior art**: Fee adjustments, rebalancing, perp hedges — all reactive, all complex, all require active management
- **PremiumYield**: A passive product. Deposit, set threshold, withdraw. IL is handled. Premiums compound in the background.

## 1.4 Functional Requirements

### FR-1: Premium Collection
- On every LP deposit, the hook calculates and collects an entry premium
- Premium is expressed as basis points of position notional value
- Premium scales dynamically with a volatility oracle reading at deposit time
- Premium range: 3–100 bps depending on volatility regime

### FR-2: Vault Deployment
- All collected premiums are immediately forwarded to an ERC4626-compatible vault
- Default vault: Aave v3 or Morpho Blue (highest liquidity, lowest smart contract risk)
- Vault is upgradeable via governance to migrate to higher-yield sources
- Hook holds ERC4626 shares, not raw assets, to track per-LP accrual

### FR-3: IL Calculation at Withdrawal
- On withdrawal, hook queries the pool's TWAP oracle for entry vs. exit price
- Hook computes the LP's realized IL using the standard formula against a hypothetical hold portfolio
- IL is expressed in USD terms using Chainlink price feed

### FR-4: Claim Processing
- If LP's realized IL > user-set threshold: hook pays out the delta from vault
- Payout source priority: vault yield first, then vault principal
- If vault is insufficient (extreme event): payout is pro-rated; shortfall is tracked as debt for future premium accrual
- If LP's realized IL < threshold: LP receives premium back + pro-rata vault yield earned during their tenure

### FR-5: Volatility-Scaled Premiums
- Hook reads a 24hr realized volatility metric from an on-chain oracle (Uniswap v4 TWAP-derived or Chainlink vol feed)
- Four volatility regimes with corresponding premium multipliers:

| Regime | Condition | Premium Multiplier |
|---|---|---|
| Calm | σ < 20% annualized | 1.0x (base rate) |
| Normal | 20% ≤ σ < 50% | 1.5x |
| Elevated | 50% ≤ σ < 100% | 2.5x |
| Extreme | σ ≥ 100% | 4.0x |

### FR-6: LP Configurability
- LPs set their IL coverage threshold at deposit time (e.g., "cover me if IL exceeds 5%")
- LPs can optionally opt out of insurance (no premium charged, no coverage)
- LPs cannot change threshold after deposit (prevents gaming at withdrawal)

### FR-7: Fund Solvency Guardrails
- Hook maintains a minimum solvency ratio: vault TVL / outstanding coverage liability ≥ 110%
- If ratio drops below 110%: new deposits are paused until ratio recovers
- Hook emits `SolvencyWarning` event when ratio drops below 120% for monitoring

## 1.5 Non-Functional Requirements

- **Gas efficiency**: Premium collection and vault deposit must add < 50k gas to LP deposit flow
- **Upgradeable vault**: Vault address is changeable via timelock (48hr delay) without migrating hook
- **Oracle fallback**: If primary vol oracle fails, hook falls back to a hardcoded "normal" regime rather than reverting
- **Reentrancy safety**: All vault interactions follow checks-effects-interactions; vault calls are last in execution order

## 1.6 Success Metrics (Demo Day)

- Demonstrate a full LP lifecycle: deposit → premium collected → price moves → withdrawal with IL claim payout
- Demonstrate a full LP lifecycle where no IL occurs: deposit → withdrawal with premium refund + yield
- Show vault balance growing during a simulation with multiple LPs
- Show solvency ratio monitoring working correctly

---

# 2. Deep Technical Architecture

## 2.1 System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        Uniswap v4 Pool                          │
│                                                                 │
│  ┌─────────────┐    beforeAddLiquidity    ┌──────────────────┐  │
│  │   LP Wallet │ ───────────────────────► │  PremiumYield    │  │
│  │             │    afterRemoveLiquidity  │     Hook         │  │
│  │             │ ◄─────────────────────── │                  │  │
│  └─────────────┘                          └────────┬─────────┘  │
│                                                    │            │
└────────────────────────────────────────────────────┼────────────┘
                                                     │
                    ┌────────────────────────────────┼──────────────────────┐
                    │                                │                      │
                    ▼                                ▼                      ▼
          ┌──────────────────┐           ┌──────────────────┐   ┌──────────────────┐
          │  PremiumVault    │           │  VolatilityOracle│   │  TWAPOracle      │
          │  (ERC4626)       │           │  (Chainlink/     │   │  (v4 pool state) │
          │                  │           │   Uniswap TWAP)  │   │                  │
          │  - Aave v3       │           │  - 24hr σ        │   │  - Entry price   │
          │  - Morpho Blue   │           │  - Regime calc   │   │  - Exit price    │
          │  - Yield accrual │           │                  │   │  - IL calc       │
          └──────────────────┘           └──────────────────┘   └──────────────────┘
```

## 2.2 Hook Lifecycle — Full Call Flow

### On LP Deposit (`beforeAddLiquidity`)

```
1. LP calls PoolManager.modifyLiquidity() with positive liquidityDelta
2. Hook fires beforeAddLiquidity
3. Hook reads volatility from VolatilityOracle → determines regime
4. Hook calculates premium: premiumBps = baseBps * regimeMultiplier
5. Hook calculates notional: notional = sqrtPriceX96 * liquidity (simplified)
6. Hook transfers premium from LP to itself (requires LP approval pre-deposit)
7. Hook records LPPosition struct:
   {
     owner: address,
     liquidityAdded: uint128,
     entryPrice: uint256,        // from TWAP at block
     entryTimestamp: uint256,
     coverageThreshold: uint256, // in bps, set by LP
     premiumPaid: uint256,
     vaultSharesEarned: uint256, // tracked separately
     active: bool
   }
8. Hook deposits premium into ERC4626 vault → receives vault shares
9. Hook records vault shares against LP's position ID
10. Hook returns Hooks.BEFORE_ADD_LIQUIDITY_FLAG to allow deposit to proceed
```

### On LP Withdrawal (`afterRemoveLiquidity`)

```
1. LP calls PoolManager.modifyLiquidity() with negative liquidityDelta
2. Pool processes withdrawal normally, returns tokens to hook callback
3. Hook fires afterRemoveLiquidity
4. Hook looks up LP's LPPosition by (owner, tickLower, tickUpper)
5. Hook queries TWAP oracle for current price
6. Hook calculates realized IL:
   a. holdValue = entryTokenA * exitPriceA + entryTokenB * exitPriceB
   b. lpValue = withdrawnTokenA * exitPriceA + withdrawnTokenB * exitPriceB
   c. IL = (holdValue - lpValue) / holdValue  [in bps]
7. Hook redeems LP's vault shares → receives premium + accrued yield
8. IF IL > coverageThreshold:
   a. payoutAmount = (IL - coverageThreshold) * positionValue
   b. Hook transfers payout from vault to LP
   c. Remaining vault balance (if any) goes to fund reserves
9. IF IL <= coverageThreshold:
   a. Hook returns full premium + pro-rata vault yield to LP
10. Hook deletes LPPosition record
11. Hook emits ClaimProcessed or PremiumReturned event
```

## 2.3 Smart Contract Architecture

### Contract 1: `PremiumYieldHook.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {IERC4626} from "openzeppelin/interfaces/IERC4626.sol";
import {IVolatilityOracle} from "./interfaces/IVolatilityOracle.sol";
import {ILCalculator} from "./libraries/ILCalculator.sol";

contract PremiumYieldHook is BaseHook {
    
    // ── Storage ──────────────────────────────────────────────────────────
    
    struct LPPosition {
        address owner;
        uint128 liquidityAdded;
        uint256 entryPrice;          // sqrtPriceX96 at deposit
        uint256 entryTimestamp;
        uint256 coverageThresholdBps; // IL % above which payout triggers
        uint256 premiumPaid;          // in token0 terms
        uint256 vaultShares;          // ERC4626 shares owned by this position
        bool active;
    }
    
    // positionId => LPPosition
    // positionId = keccak256(owner, poolId, tickLower, tickUpper, depositTimestamp)
    mapping(bytes32 => LPPosition) public positions;
    
    // poolId => total outstanding coverage liability (in token0)
    mapping(bytes32 => uint256) public totalCoverageLIABILITY;
    
    // poolId => vault address
    mapping(bytes32 => address) public poolVault;
    
    // Volatility oracle
    IVolatilityOracle public immutable volOracle;
    
    // Base premium in bps (e.g. 5 = 0.05%)
    uint256 public constant BASE_PREMIUM_BPS = 5;
    
    // Solvency ratio floor (110% = 11000 in bps-style)
    uint256 public constant MIN_SOLVENCY_RATIO = 11000;
    
    // ── Events ────────────────────────────────────────────────────────────
    
    event PremiumCollected(
        bytes32 indexed positionId,
        address indexed lp,
        uint256 premiumAmount,
        uint256 vaultShares,
        uint8 volatilityRegime
    );
    
    event ClaimProcessed(
        bytes32 indexed positionId,
        address indexed lp,
        uint256 ilBps,
        uint256 payoutAmount
    );
    
    event PremiumReturned(
        bytes32 indexed positionId,
        address indexed lp,
        uint256 premiumReturned,
        uint256 yieldEarned
    );
    
    event SolvencyWarning(bytes32 indexed poolId, uint256 currentRatio);
    
    // ── Hook Permissions ──────────────────────────────────────────────────
    
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,     // collect premium
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,   // process claim or return premium
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: true // inject payout into delta
        });
    }
    
    // ── Core Hook Logic ───────────────────────────────────────────────────
    
    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4) {
        
        // Decode LP preferences from hookData
        (uint256 coverageThresholdBps, bool wantsInsurance) = abi.decode(
            hookData, (uint256, bool)
        );
        
        if (!wantsInsurance) return BaseHook.beforeAddLiquidity.selector;
        
        // Get current volatility regime
        uint8 regime = volOracle.getCurrentRegime(key.currency0, key.currency1);
        uint256 premiumMultiplier = _getMultiplier(regime);
        
        // Calculate premium
        uint256 notional = _estimateNotional(params, key);
        uint256 premiumBps = (BASE_PREMIUM_BPS * premiumMultiplier) / 100;
        uint256 premiumAmount = (notional * premiumBps) / 10000;
        
        // Collect premium from sender (requires prior approval)
        IERC20(Currency.unwrap(key.currency0)).transferFrom(
            sender, address(this), premiumAmount
        );
        
        // Deploy to vault
        address vault = poolVault[key.toId()];
        IERC20(Currency.unwrap(key.currency0)).approve(vault, premiumAmount);
        uint256 sharesReceived = IERC4626(vault).deposit(premiumAmount, address(this));
        
        // Record position
        bytes32 posId = _positionId(sender, key, params);
        positions[posId] = LPPosition({
            owner: sender,
            liquidityAdded: uint128(params.liquidityDelta),
            entryPrice: _getCurrentPrice(key),
            entryTimestamp: block.timestamp,
            coverageThresholdBps: coverageThresholdBps,
            premiumPaid: premiumAmount,
            vaultShares: sharesReceived,
            active: true
        });
        
        // Track coverage liability
        totalCoverageLIABILITY[key.toId()] += _maxCoverageAmount(notional, coverageThresholdBps);
        
        emit PremiumCollected(posId, sender, premiumAmount, sharesReceived, regime);
        
        return BaseHook.beforeAddLiquidity.selector;
    }
    
    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        
        bytes32 posId = _positionId(sender, key, params);
        LPPosition storage pos = positions[posId];
        
        if (!pos.active) return (BaseHook.afterRemoveLiquidity.selector, delta);
        
        // Calculate realized IL
        uint256 exitPrice = _getCurrentPrice(key);
        uint256 ilBps = ILCalculator.calculate(
            pos.entryPrice,
            exitPrice,
            pos.liquidityAdded
        );
        
        // Redeem vault shares
        address vault = poolVault[key.toId()];
        uint256 vaultRedemptionValue = IERC4626(vault).redeem(
            pos.vaultShares,
            address(this),
            address(this)
        );
        
        uint256 yieldEarned = vaultRedemptionValue > pos.premiumPaid
            ? vaultRedemptionValue - pos.premiumPaid
            : 0;
        
        BalanceDelta hookDelta;
        
        if (ilBps > pos.coverageThresholdBps) {
            // CLAIM: pay out IL above threshold
            uint256 positionValue = _getPositionValue(delta, key);
            uint256 payoutAmount = _calculatePayout(ilBps, pos.coverageThresholdBps, positionValue);
            
            // Cap payout at vault redemption value
            payoutAmount = payoutAmount > vaultRedemptionValue ? vaultRedemptionValue : payoutAmount;
            
            // Inject payout into delta (LP receives extra tokens)
            hookDelta = _buildPayoutDelta(payoutAmount, key);
            
            emit ClaimProcessed(posId, sender, ilBps, payoutAmount);
        } else {
            // NO CLAIM: return premium + yield to LP
            hookDelta = _buildPayoutDelta(vaultRedemptionValue, key);
            
            emit PremiumReturned(posId, sender, pos.premiumPaid, yieldEarned);
        }
        
        // Cleanup
        pos.active = false;
        totalCoverageLIABILITY[key.toId()] -= _maxCoverageAmount(
            _getPositionValue(delta, key), pos.coverageThresholdBps
        );
        
        // Solvency check
        _checkSolvency(key);
        
        return (BaseHook.afterRemoveLiquidity.selector, hookDelta);
    }
    
    // ── Internal Helpers ──────────────────────────────────────────────────
    
    function _getMultiplier(uint8 regime) internal pure returns (uint256) {
        if (regime == 0) return 100;  // 1.0x
        if (regime == 1) return 150;  // 1.5x
        if (regime == 2) return 250;  // 2.5x
        return 400;                   // 4.0x
    }
    
    function _checkSolvency(PoolKey calldata key) internal {
        address vault = poolVault[key.toId()];
        uint256 vaultValue = IERC4626(vault).totalAssets();
        uint256 liability = totalCoverageLIABILITY[key.toId()];
        
        if (liability == 0) return;
        
        uint256 ratio = (vaultValue * 10000) / liability;
        
        if (ratio < 12000) { // 120% warning threshold
            emit SolvencyWarning(key.toId(), ratio);
        }
    }
    
    // ... additional helpers: _positionId, _getCurrentPrice, _estimateNotional,
    //     _calculatePayout, _buildPayoutDelta, _getPositionValue
}
```

### Contract 2: `ILCalculator.sol` (Library)

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

library ILCalculator {
    
    /// @notice Calculate impermanent loss in basis points
    /// @param entryPrice sqrtPriceX96 at LP entry
    /// @param exitPrice  sqrtPriceX96 at LP exit
    /// @return ilBps IL as basis points of initial position value
    function calculate(
        uint256 entryPrice,
        uint256 exitPrice,
        uint128 /*liquidity*/
    ) internal pure returns (uint256 ilBps) {
        
        // Convert sqrtPriceX96 to price ratio
        // priceRatio = (exitPrice / entryPrice)^2
        // IL formula: IL = 2*sqrt(r)/(1+r) - 1 where r = price ratio
        
        if (entryPrice == 0) return 0;
        
        // Using fixed-point math to avoid overflow
        // r = (exitPrice^2) / (entryPrice^2)
        uint256 sqrtR_num = exitPrice;
        uint256 sqrtR_den = entryPrice;
        
        // IL = 2*sqrt(r)/(1+r) - 1
        // Multiply through: IL_bps = (2 * sqrtR_num * 10000) / (sqrtR_num + sqrtR_den) - 10000
        
        uint256 numerator = 2 * sqrtR_num * 10000;
        uint256 denominator = sqrtR_num + sqrtR_den;
        
        if (denominator == 0) return 0;
        
        uint256 twoSqrtR_over_onePlusR = numerator / denominator;
        
        // IL is always negative; return absolute value in bps
        if (twoSqrtR_over_onePlusR >= 10000) {
            return 0; // No IL (r == 1, no price change)
        }
        
        return 10000 - twoSqrtR_over_onePlusR;
    }
}
```

### Contract 3: `VolatilityOracle.sol`

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IUniswapV3Pool} from "v3-core/interfaces/IUniswapV3Pool.sol";

contract VolatilityOracle {
    
    // Regime thresholds (annualized vol in bps: 2000 = 20%)
    uint256 public constant CALM_THRESHOLD    = 2000;
    uint256 public constant NORMAL_THRESHOLD  = 5000;
    uint256 public constant ELEVATED_THRESHOLD = 10000;
    
    // Returns: 0=Calm, 1=Normal, 2=Elevated, 3=Extreme
    function getCurrentRegime(
        address currency0,
        address currency1
    ) external view returns (uint8) {
        uint256 vol = _getAnnualizedVol(currency0, currency1);
        
        if (vol < CALM_THRESHOLD)     return 0;
        if (vol < NORMAL_THRESHOLD)   return 1;
        if (vol < ELEVATED_THRESHOLD) return 2;
        return 3;
    }
    
    function _getAnnualizedVol(
        address /*currency0*/,
        address /*currency1*/
    ) internal view returns (uint256) {
        // Implementation: query Chainlink vol feed or
        // derive from Uniswap v4 TWAP price history
        // Returns annualized vol in bps
        
        // Simplified: use log returns from TWAP observations
        // Full implementation uses tick history from pool observations array
        
        return 3000; // placeholder: 30% annualized
    }
}
```

## 2.4 Data Flow Diagram

```
LP Deposit Flow:
─────────────────────────────────────────────────────────────
LP Wallet
  │
  ├── 1. approve(hook, premiumAmount)          // ERC20 approval
  │
  └── 2. modifyLiquidity(key, params, hookData)
             │
             ▼
        PoolManager
             │
             ├── 3. beforeAddLiquidity() ──► PremiumYieldHook
             │                                    │
             │                                    ├── 4. volOracle.getCurrentRegime()
             │                                    ├── 5. calculate premium
             │                                    ├── 6. transferFrom(LP, hook, premium)
             │                                    ├── 7. vault.deposit(premium)
             │                                    └── 8. store LPPosition
             │
             └── 9. execute liquidity addition
             
LP Withdrawal Flow:
─────────────────────────────────────────────────────────────
LP Wallet
  │
  └── 1. modifyLiquidity(key, params, hookData)
             │
             ▼
        PoolManager
             │
             ├── 2. execute liquidity removal (returns tokens to hook)
             │
             └── 3. afterRemoveLiquidity() ──► PremiumYieldHook
                                                   │
                                                   ├── 4. load LPPosition
                                                   ├── 5. getTWAP(exitPrice)
                                                   ├── 6. ILCalculator.calculate(entry, exit)
                                                   ├── 7. vault.redeem(shares)
                                                   ├── 8. IF ilBps > threshold:
                                                   │       └── build payout delta
                                                   │   ELSE:
                                                   │       └── return premium + yield delta
                                                   └── 9. return (selector, adjustedDelta)
```

## 2.5 Storage Layout

```
PremiumYieldHook:
├── positions: mapping(bytes32 => LPPosition)
│   └── key: keccak256(owner, poolId, tickLower, tickUpper, depositBlock)
├── totalCoverageLIABILITY: mapping(bytes32 => uint256)   // poolId => uint256
├── poolVault: mapping(bytes32 => address)                // poolId => ERC4626
└── volOracle: IVolatilityOracle (immutable)

LPPosition struct (128 bytes):
├── owner: address          (20 bytes)
├── liquidityAdded: uint128 (16 bytes)
├── entryPrice: uint256     (32 bytes)
├── entryTimestamp: uint256 (32 bytes)
├── coverageThresholdBps: uint256 (32 bytes)
├── premiumPaid: uint256    (32 bytes)
├── vaultShares: uint256    (32 bytes)
└── active: bool            (1 byte)
```

## 2.6 Security Considerations

| Risk | Mitigation |
|---|---|
| Oracle manipulation for IL calculation | Use 30-min TWAP, not spot price, for IL measurement |
| Vault rug/exploit drains insurance fund | Whitelist only audited ERC4626 vaults; timelock on vault changes |
| Premium front-running (deposit during low-vol then withdraw high-vol) | Premium locked at deposit time, not withdrawal time |
| Solvency death spiral | Hard deposit pause at 110% solvency ratio; pro-rata payouts on underfunding |
| Reentrancy via ERC4626 | All vault calls after state updates (CEI pattern strictly) |
| hookData manipulation | Validate coverageThresholdBps within allowed range (1–5000 bps) |

---

# 3. Build Guide

## 3.1 Prerequisites

```bash
# Tools required
node >= 18
foundry (forge, anvil, cast)
git

# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

## 3.2 Repository Setup

```bash
# Initialize project
forge init premium-yield-hook
cd premium-yield-hook

# Install dependencies
forge install Uniswap/v4-core
forge install Uniswap/v4-periphery
forge install OpenZeppelin/openzeppelin-contracts
forge install aave/aave-v3-core

# Configure remappings
cat > remappings.txt << 'EOF'
v4-core/=lib/v4-core/src/
v4-periphery/=lib/v4-periphery/src/
openzeppelin/=lib/openzeppelin-contracts/contracts/
EOF
```

## 3.3 Project File Structure

```
premium-yield-hook/
├── src/
│   ├── PremiumYieldHook.sol          # Main hook contract
│   ├── interfaces/
│   │   ├── IVolatilityOracle.sol
│   │   └── IPremiumVault.sol
│   ├── libraries/
│   │   ├── ILCalculator.sol          # IL math library
│   │   └── PremiumMath.sol           # Premium scaling math
│   └── oracles/
│       └── VolatilityOracle.sol      # Vol regime oracle
├── test/
│   ├── PremiumYieldHook.t.sol        # Unit tests
│   ├── Integration.t.sol             # Full lifecycle tests
│   └── mocks/
│       ├── MockERC4626Vault.sol
│       └── MockVolatilityOracle.sol
├── script/
│   ├── Deploy.s.sol                  # Deployment script
│   └── Simulate.s.sol               # Demo simulation
└── foundry.toml
```

## 3.4 Step-by-Step Build Order

### Step 1: Build the IL Calculator Library

Start here — it's pure math with no dependencies and you can test it in isolation.

```bash
# Create and test ILCalculator first
forge test --match-contract ILCalculatorTest -vvv
```

Key test cases to verify:
- `calculate(1e18, 1e18, ...)` → returns 0 (no price change = no IL)
- `calculate(1e18, 4e18, ...)` → returns ~500 bps (2x price move = ~5.7% IL)
- `calculate(1e18, 9e18, ...)` → returns ~1800 bps (3x price move = ~18.4% IL)

### Step 2: Build and Test the Volatility Oracle

```bash
# Deploy mock oracle for testing
forge test --match-contract VolatilityOracleTest -vvv
```

Test regime boundaries:
- Mock a 15% vol reading → should return regime 0 (Calm)
- Mock a 35% vol reading → should return regime 1 (Normal)
- Mock a 75% vol reading → should return regime 2 (Elevated)
- Mock a 150% vol reading → should return regime 3 (Extreme)

### Step 3: Build the Mock ERC4626 Vault

```solidity
// test/mocks/MockERC4626Vault.sol
contract MockERC4626Vault is ERC4626 {
    // Simple vault that accepts deposits and tracks shares
    // Add a function to simulate yield accrual for tests
    
    function simulateYield(uint256 yieldAmount) external {
        // Mint additional underlying to vault to simulate yield
        MockERC20(asset()).mint(address(this), yieldAmount);
    }
}
```

### Step 4: Build the Main Hook

```bash
# Compile hook
forge build

# Check for hook address mining requirement
# Uniswap v4 hooks must be deployed at addresses with specific bits set
# Use the HookMiner utility from v4-periphery
```

Hook address mining:
```solidity
// script/Deploy.s.sol
import {HookMiner} from "v4-periphery/utils/HookMiner.sol";

// Flags needed: BEFORE_ADD_LIQUIDITY | AFTER_REMOVE_LIQUIDITY | AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA
uint160 flags = uint160(
    Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
    Hooks.AFTER_REMOVE_LIQUIDITY_FLAG |
    Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
);

(address hookAddress, bytes32 salt) = HookMiner.find(
    deployer,
    flags,
    type(PremiumYieldHook).creationCode,
    abi.encode(address(poolManager), address(volOracle))
);
```

### Step 5: Write Integration Tests

```solidity
// test/Integration.t.sol
contract PremiumYieldIntegrationTest is Test {
    
    function test_FullLifecycle_ClaimTriggered() public {
        // 1. Deploy hook, pool, mock vault, mock oracle
        // 2. LP deposits 100 USDC / 0.05 ETH with 3% threshold
        // 3. Price moves 2x (ETH price doubles)
        // 4. LP withdraws — expect IL ~5.7%, above 3% threshold
        // 5. Assert LP received payout covering the 2.7% excess IL
        // 6. Assert vault balance reduced by payout amount
    }
    
    function test_FullLifecycle_NoClaim_YieldReturned() public {
        // 1. Deploy hook, pool, mock vault, mock oracle
        // 2. Simulate vault yield accrual (e.g., 5% APY over 30 days)
        // 3. LP deposits with 10% IL threshold
        // 4. Price moves only 5% (IL ~0.03%, below threshold)
        // 5. LP withdraws — expect premium + vault yield returned
        // 6. Assert LP received more than they paid in premium
    }
    
    function test_SolvencyPause() public {
        // 1. Multiple LPs deposit creating large coverage liability
        // 2. Drain vault to simulate losses
        // 3. Assert new deposits are paused when ratio < 110%
        // 4. Assert SolvencyWarning emitted when ratio < 120%
    }
    
    function test_VolatilityRegimeScaling() public {
        // 1. Set oracle to Extreme regime
        // 2. Deposit LP — assert premium = 4x base rate
        // 3. Set oracle to Calm regime
        // 4. Deposit LP — assert premium = 1x base rate
    }
}
```

### Step 6: Local Simulation with Anvil

```bash
# Start local node
anvil --fork-url $MAINNET_RPC_URL --fork-block-number 21000000

# Deploy everything
forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast

# Run simulation script
forge script script/Simulate.s.sol --rpc-url http://localhost:8545 --broadcast -vvvv
```

### Step 7: Demo Day Simulation Script

```solidity
// script/Simulate.s.sol
// This script runs a full demo walkthrough for judges:

// Act 1: LP Alice deposits during Normal volatility, IL stays low
//   → Show: Alice gets premium back + yield (win for LPs)

// Act 2: LP Bob deposits during Elevated volatility, price crashes 3x
//   → Show: Bob's IL is 25%, threshold was 5%, Bob receives 20% payout
//   → Show: Vault paid out from yield first, then principal

// Act 3: Show solvency ratio remaining healthy throughout
// Act 4: Add 5 more LPs — show vault growing, yield compounding
```

## 3.5 Testing Checklist

```
□ ILCalculator returns correct values for known price moves
□ VolatilityOracle returns correct regime for each threshold
□ Premium correctly scales with each volatility regime
□ Vault shares correctly tracked per LP position
□ Claim payout triggers when IL > threshold
□ Premium + yield returned when IL ≤ threshold
□ Solvency check emits warning at 120%
□ New deposits paused at 110% solvency ratio
□ Oracle fallback works when primary feed fails
□ Reentrancy: no state changes after vault call succeed
□ hookData manipulation: invalid thresholds rejected
□ Position cleanup: LPPosition.active = false after withdrawal
```

## 3.6 Deployment Checklist

```bash
# Testnet deployment (Sepolia or Base Sepolia)
forge script script/Deploy.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_KEY

# Verify contracts
forge verify-contract $HOOK_ADDRESS PremiumYieldHook \
  --chain sepolia \
  --etherscan-api-key $ETHERSCAN_KEY
```

## 3.7 Demo Day Narrative

**Opening**: "LPs lose billions to impermanent loss every year. Existing solutions try to reduce it. We decided to insure against it — and make money while doing it."

**Core demo flow**:
1. Show two LP deposits (one that will claim, one that won't)
2. Advance block time, simulate price movement
3. Show vault accruing yield in real-time
4. Process both withdrawals
5. Show Claimer received payout. Show non-claimer got premium back + yield.
6. Show vault solvency dashboard

**Closing**: "We turned a cost center into a yield engine. The insurance fund is always working, whether LPs claim or not."

---

*Built for UHI9 Hookathon | May 25, 2026*
