# PremiumYield Hook

> **IL Insurance Fund Where the Premiums Earn Yield**
---

## Overview

PremiumYield is a Uniswap v4 hook that solves the single biggest barrier to passive LP participation: **impermanent loss (IL)**. Instead of reacting to IL after it happens, PremiumYield builds a structurally capitalized, yield-bearing insurance fund directly into the liquidity layer.

Every LP pays a small volatility-scaled premium at deposit. That premium is immediately deployed to an ERC4626 vault (Aave, Morpho Blue) and earns yield. At withdrawal the LP is whole — either their IL is covered from vault proceeds, or their premium plus accrued yield is returned to them.

> *"You pay a small premium on entry. If IL destroys your position, you're covered. If it doesn't, you earn yield on your own insurance premium. Either way, you win."*

---

## 1. Problem Statement

Impermanent loss is the primary reason sophisticated capital avoids providing liquidity on Uniswap. When price moves away from a position's entry point, LPs lose value relative to simply holding the underlying tokens. The greater the price divergence, the greater the loss.

**Existing approaches all fail the same way:**

| Approach | Flaw |
|---|---|
| Dynamic fee adjustment | Reactive — fees cannot recover already-realized IL |
| Active rebalancing | Requires management, eats into returns, introduces new risks |
| Perp hedges | Complex, expensive, requires separate infrastructure |
| Range compression | Reduces IL exposure but increases out-of-range time and concentration risk |

None of these approaches treat the insurance fund as a **productive asset**. They either cost money passively or require active management. PremiumYield does neither.

---

## 2. Solution

PremiumYield treats the IL insurance fund as an **earning asset**, not a cost center.

**The structural innovation:**

1. Premiums are not held idle — they are deployed to a yield-bearing ERC4626 vault from the moment of deposit.
2. Every premium dollar earns yield continuously, whether or not an LP ever claims.
3. LPs who do not experience significant IL receive their premium **back with interest** at withdrawal.
4. LPs who do experience significant IL receive a **payout that covers the loss above their chosen threshold**.

This creates a product where LPs face no bad outcome. The fund capitalizes itself through yield accrual, and coverage is provided structurally rather than reactively.

**Target users:**

| User Segment | Problem | How PremiumYield Solves It |
|---|---|---|
| Passive LPs | IL destroys returns unpredictably | Guaranteed IL coverage above threshold |
| Yield-seeking LPs | Fee APY is inconsistent | Premium vault yield supplements fee income |
| Protocol treasuries | Need predictable LP returns | Insurance + yield creates a predictable floor |
| Insurance underwriters | No DeFi-native LP insurance market | Fund structure enables future underwriter participation |

---

## 3. How It Works

### Deposit Flow

1. LP calls `PoolManager.modifyLiquidity()` with a positive `liquidityDelta`
2. The hook fires `beforeAddLiquidity`
3. The hook reads the current volatility regime from the oracle
4. The hook calculates a premium: `notional × baseBps × regimeMultiplier`
5. The hook pulls the premium from the LP's wallet via `transferFrom` (LP pre-approves the hook)
6. The premium is deposited into an ERC4626 vault — the hook receives vault shares on behalf of the LP
7. The hook records an `LPPosition` struct: entry price, liquidity delta, threshold, vault shares
8. Liquidity addition proceeds normally through the PoolManager

### Withdrawal Flow

1. LP calls `PoolManager.modifyLiquidity()` with a negative `liquidityDelta`
2. The hook fires `afterRemoveLiquidity`
3. The hook loads the LP's `LPPosition` record using the LP address from hookData
4. The hook reads the current pool price and computes realized IL via `ILCalculator`
5. The hook redeems the LP's vault shares, receiving the original premium plus accrued yield
6. **If IL > threshold:** the hook pays out `(IL − threshold) × positionValue` from vault proceeds; the surplus stays as fund reserves
7. **If IL ≤ threshold:** the hook returns the full vault redemption value (premium + yield) to the LP
8. The `LPPosition` is marked inactive; coverage liability is decremented
9. A solvency check runs; deposits are auto-paused if vault TVL / coverage liability < 110%

### LP Decision Tree at Deposit

```
                    ┌────────────────────────────────────────┐
                    │  LP adds liquidity via modifyLiquidity │
                    └──────────────────┬─────────────────────┘
                                       │ hookData:
                                       │ abi.encode(thresholdBps, wantsInsurance, lpAddress)
                         ┌─────────────▼────────────────┐
                         │     wantsInsurance = false?  │
                         └─────────────┬────────────────┘
                           YES ◄───────┴───────► NO
                            │                    │
                    No premium charged      Pay small premium
                    No IL coverage         Set coverage threshold
                            │                    │
                            └──────┬─────────────┘
                                   │
                         Liquidity added to pool
```

---

## 4. Volatility-Scaled Premiums

The base premium rate is **5 bps (0.05%)** of position notional value, scaled by the current volatility regime at deposit time. The regime is determined by the `VolatilityOracle`, which reads 24-hour realized volatility from a Chainlink feed or derives it from Uniswap v4 pool observations.

| Regime | Annualized Volatility | Multiplier | Effective Premium |
|---|---|---|---|
| **Calm** | σ < 20% | 1.0× | 5 bps |
| **Normal** | 20% ≤ σ < 50% | 1.5× | 7.5 bps |
| **Elevated** | 50% ≤ σ < 100% | 2.5× | 12.5 bps |
| **Extreme** | σ ≥ 100% | 4.0× | 20 bps |

**Oracle fallback:** If the volatility oracle becomes unavailable, the hook silently defaults to the Normal regime rather than reverting, preserving liveness at the cost of slightly reduced premium accuracy.

**Premium lock:** The regime multiplier is captured at deposit time and cannot change. This prevents LPs from gaming the system by depositing during low-volatility windows and withdrawing after a high-volatility event.

**Position notional estimate:** `notional ≈ liquidity × Q96 / sqrtPriceX96`, giving an approximate token0-denominated size of the position at the current price.

---

## 5. System Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                         Uniswap v4 Pool                          │
│                                                                  │
│  ┌─────────────┐    beforeAddLiquidity     ┌──────────────────┐  │
│  │   LP Wallet │ ────────────────────────► │  PremiumYield    │  │
│  │             │    afterRemoveLiquidity   │     Hook         │  │
│  │             │ ◄──────────────────────── │                  │  │
│  └─────────────┘                           └────────┬─────────┘  │
│                                                     │            │
└─────────────────────────────────────────────────────┼────────────┘
                                                      │
                    ┌─────────────────────────────────┼────────────────────┐
                    │                                 │                    │
                    ▼                                 ▼                    ▼
          ┌──────────────────┐            ┌──────────────────┐  ┌──────────────────┐
          │  ERC4626 Vault   │            │ VolatilityOracle │  │  Pool sqrtPrice  │
          │                  │            │                  │  │  (StateLibrary)  │
          │  Aave v3 /       │            │  24hr σ (bps)    │  │                  │
          │  Morpho Blue     │            │  4 regimes       │  │  Entry price     │
          │  Yield accrual   │            │  Oracle fallback │  │  Exit price      │
          │  Per-LP shares   │            │                  │  │  IL calculation  │
          └──────────────────┘            └──────────────────┘  └──────────────────┘
```

### Hook Flags

The hook contract must be deployed at an address where the lower 14 bits match the required permissions:

```
BEFORE_ADD_LIQUIDITY_FLAG                 = 1 << 11 = 0x800
AFTER_REMOVE_LIQUIDITY_FLAG               = 1 << 8  = 0x100
AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG = 1 << 0  = 0x001
                                                       ─────
Required address mask:                                 0x901
```

In tests this is achieved with `vm.etch(address(uint160(0x901)), impl.code)`. In production, a CREATE2 salt is mined until the resulting address carries the `0x901` bits.

### Solvency Guardrails

The hook monitors the ratio of vault TVL to outstanding maximum coverage liability after every withdrawal:

```
solvencyRatio = vault.totalAssets() / totalCoverageLiability × 10000
```

| Ratio | Action |
|---|---|
| ≥ 12000 (120%) | Normal operation |
| < 12000 (120%) | Emit `SolvencyWarning` event for monitoring |
| < 11000 (110%) | Auto-pause all new insured deposits for this pool |

Maximum coverage liability per position: `(10000 − thresholdBps) × notional / 10000` — the worst-case payout if IL reaches 100%.

---

## 6. Smart Contract Deep Dive

### Contract Map

```
src/
├── PremiumYieldHook.sol          ← Main hook (implements IHooks directly)
├── interfaces/
│   └── IVolatilityOracle.sol     ← Oracle interface
├── libraries/
│   └── ILCalculator.sol          ← Overflow-safe IL math (FullMath-based)
└── oracles/
    └── VolatilityOracle.sol      ← 4-regime oracle with per-pair overrides
```

---

### `PremiumYieldHook.sol`

The central contract. Implements `IHooks` directly without v4-periphery.

**Key constants:**

```solidity
uint256 public constant BASE_PREMIUM_BPS      = 5;      // 0.05% base rate
uint256 public constant MIN_SOLVENCY_RATIO_BPS = 11_000; // 110% — auto-pause floor
uint256 public constant SOLVENCY_WARNING_BPS   = 12_000; // 120% — warning threshold
uint256 public constant MIN_COVERAGE_BPS       = 1;      // 0.01% minimum threshold
uint256 public constant MAX_COVERAGE_BPS       = 5_000;  // 50%  maximum threshold
```

**Storage layout:**

```solidity
struct LPPosition {
    address owner;               // LP wallet address
    uint128 liquidityAdded;      // liquidity units at deposit
    uint160 entryPrice;          // sqrtPriceX96 at deposit block
    uint256 entryTimestamp;      // block.timestamp at deposit
    uint256 coverageThresholdBps;// IL% above which payout triggers (1–5000)
    uint256 premiumPaid;         // currency0 amount collected
    uint256 vaultShares;         // ERC4626 shares held for this position
    bool    active;              // false after withdrawal or claim
}

// position key: keccak256(lpAddress, poolId, tickLower, tickUpper, salt)
mapping(bytes32 => LPPosition) public positions;

mapping(bytes32 => uint256) public totalCoverageLiability; // poolId → max payout sum
mapping(bytes32 => address) public poolVault;              // poolId → ERC4626 vault
mapping(bytes32 => bool)    public depositsPausedMap;      // poolId → solvency pause
```

**hookData encoding:**

```solidity
// On addLiquidity — includes LP wallet so hook can pull premium directly
bytes memory hookData = abi.encode(
    uint256 coverageThresholdBps,  // 1–5000 bps (LP's IL deductible)
    bool    wantsInsurance,        // false = opt out, no premium, no coverage
    address lp                     // actual LP wallet (pre-approves hook for premium)
);

// On removeLiquidity — just the LP wallet to look up the position record
bytes memory hookData = abi.encode(address lp);
```

> **Why include `lp` in hookData?**
> In Uniswap v4's unlock/callback model the `sender` passed to hook callbacks is the *router* contract that called `modifyLiquidity`, not the LP's own wallet. To pull the premium from the correct address and look up the correct position record, the actual LP address must be explicitly passed through hookData.

**Delta injection pattern for payout:**

The hook uses `AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG` to inject tokens into the LP's settlement without bypassing the PoolManager's accounting:

```
1. vault.redeem(shares)                  → hook holds currency0 tokens
2. poolManager.sync(currency0)           → snapshot PM's current token0 balance
3. token0.transfer(poolManager, amount)  → transfer tokens to PoolManager
4. poolManager.settle()                  → PM credits hook's delta: +amount
5. return toBalanceDelta(-amount, 0)     → hook delta net: (+amount) + (-amount) = 0
                                            LP's callerDelta:                  += amount ✓
```

This pattern keeps the PoolManager's accounting invariants intact while delivering tokens to the LP as part of normal settlement.

---

### `ILCalculator.sol`

A pure math library using the standard Uniswap impermanent loss formula:

```
IL = 1 - 2√r / (1 + r)
```

where `r = (exitSqrtPrice / entrySqrtPrice)²` is the realized price ratio. Because Uniswap stores `sqrtPriceX96`, the ratio of sqrtPrices equals `√r` directly, simplifying the formula.

**Overflow-safe implementation using FullMath:**

Raw `sqrtPriceX96` values can be up to ~2¹⁶⁰, so squaring them overflows `uint256`. The library normalizes to a 1e9 fixed-point ratio before squaring:

```solidity
// Normalize: k = max(entry, exit) / min(entry, exit) × 1e9
// k ∈ [1e9, 1e27] — k² fits comfortably in uint256 (max 1e54 << 1.15e77)
uint256 k = FullMath.mulDiv(b, 1e9, a);
if (k > 1e27) k = 1e27; // clamp for extreme moves

// IL_bps = 10000 - (2 × 10000 × 1e9 × k) / (k² + 1e18)
uint256 numerator   = 2 * 10_000 * 1e9 * k;
uint256 denominator = k * k + 1e18;
```

**Known IL reference values:**

| Actual Price Move | sqrtPrice Ratio | IL |
|---|---|---|
| No change | 1.000× | 0 bps |
| +10% | 1.049× | ~12 bps |
| 2× | 1.414× (√2) | ~572 bps |
| 4× | 2.000× | 2000 bps |
| 9× | 3.000× | 4000 bps |
| 100× | 10.00× | ~9802 bps |

IL is symmetric: a 4× price increase and a 4× price decrease both produce 2000 bps IL.

---

### `VolatilityOracle.sol`

Maps annualized volatility (in bps) to one of four regimes. Uses a Chainlink feed or Uniswap v4 tick history in production; for the demo it returns a configurable default of 30% (Normal regime) with per-pair overrides settable by the owner.

```solidity
function getCurrentRegime(address currency0, address currency1)
    external view returns (uint8);
// Returns: 0=Calm | 1=Normal | 2=Elevated | 3=Extreme

// Regime thresholds (annualized vol in bps):
uint256 public constant CALM_THRESHOLD     = 2_000;  // 20%
uint256 public constant NORMAL_THRESHOLD   = 5_000;  // 50%
uint256 public constant ELEVATED_THRESHOLD = 10_000; // 100%
```

The oracle also exposes `setVolOverride(currency0, currency1, volBps)` for the owner to pin a specific volatility reading — useful for demo and testnet scenarios.

---

## 7. Data Flow

### LP Deposit

```
LP Wallet
  │
  ├── 1. token0.approve(hook, estimatedPremium)
  │
  └── 2. router.modifyLiquidity(poolKey, addParams,
              abi.encode(thresholdBps, true, lpAddress))
                   │
                   ▼
            PoolManager.unlock()
                   │
                   └── PoolManager.modifyLiquidity()
                              │
                              ├── hook.beforeAddLiquidity()
                              │         │
                              │         ├── volOracle.getCurrentRegime()  → regime
                              │         ├── estimate notional = liq × Q96 / sqrtP
                              │         ├── premium = notional × baseBps × multiplier / BPS
                              │         ├── token0.transferFrom(lp, hook, premium)
                              │         ├── vault.deposit(premium) → shares
                              │         ├── store LPPosition{..., vaultShares}
                              │         └── totalCoverageLiability += maxCoverage
                              │
                              └── execute liquidity addition in pool
```

### LP Withdrawal

```
LP Wallet
  │
  └── router.modifyLiquidity(poolKey, removeParams,
            abi.encode(lpAddress))
                   │
                   ▼
            PoolManager.unlock()
                   │
                   └── PoolManager.modifyLiquidity()
                              │
                              ├── execute liquidity removal
                              │
                              └── hook.afterRemoveLiquidity()
                                            │
                                            ├── load LPPosition[lp, pool, ticks, salt]
                                            ├── exitPrice = pool.getSlot0().sqrtPriceX96
                                            ├── ilBps = ILCalculator.calculate(entry, exit)
                                            ├── proceeds = vault.redeem(shares) → token0
                                            │
                                            ├── [IL > threshold]
                                            │     payout = (ilBps - threshold) × posValue / BPS
                                            │     payout = min(payout, proceeds)
                                            │     emit ClaimProcessed
                                            │
                                            └── [IL ≤ threshold]
                                                  payout = proceeds  (full premium + yield)
                                                  emit PremiumReturned
                                                         │
                                                  sync → transfer → settle → return delta(-payout)
                                                  [LP callerDelta += payout]
```

### Vault Yield Compounding

```
Timeline ──────────────────────────────────────────────────────────►

  LP1 deposits    LP2 deposits     LP3 deposits    LP4 claims IL
       │               │                │               │
       ▼               ▼                ▼               ▼
  premium₁ ──────► vault ◄─── premium₃ ◄── premium₂    │ pays out
                     │                                   │ from vault
                Aave / Morpho Blue                       │
                earns yield daily                        │
                     │                                   │
              vault.totalAssets() grows                  │
                     │                                   │
                     ▼                                   ▼
       LP1 withdraws (no claim):           LP4 withdraws (claim):
       gets premium₁ + yield              vault pays IL excess
       (came out ahead)                   vault keeps remainder
```

---

## 8. Security Model

| Risk | Mitigation |
|---|---|
| **Oracle price manipulation at withdrawal** | Production deployment should use a 30-minute TWAP for exit price to prevent sandwich attacks around withdrawal; spot price used in demo |
| **Vault rug or exploit drains fund** | Only whitelisted, audited ERC4626 vaults accepted; vault address changeable only via 48-hour timelock |
| **Premium front-running (deposit low-vol, withdraw high-vol)** | Multiplier locked at deposit time — the exit volatility environment is irrelevant |
| **Solvency death spiral** | Hard 110% floor auto-pauses new insured deposits; solvency recovers as existing positions close and premiums accumulate |
| **Reentrancy via ERC4626 vault** | CEI strictly enforced: `pos.active = false` before `vault.redeem()`; no state changes after the vault call |
| **hookData manipulation** | `coverageThresholdBps` validated in range `[MIN_COVERAGE_BPS, MAX_COVERAGE_BPS]`; hookData length checked before decoding |
| **Invalid LP address in hookData** | If no position exists for the decoded LP address, hook returns `ZERO_DELTA` and continues without reverting |
| **Coverage liability underflow** | `totalCoverageLiability` decrement uses a saturating subtraction (`>= check before -=`) |

---

## 9. Repository Structure

```
PremiumYield/
├── src/
│   ├── PremiumYieldHook.sol          # Main hook — premium, vault, IL payout
│   ├── interfaces/
│   │   └── IVolatilityOracle.sol     # Oracle interface
│   ├── libraries/
│   │   └── ILCalculator.sol          # IL = 1 - 2√r/(1+r), overflow-safe
│   └── oracles/
│       └── VolatilityOracle.sol      # 4-regime oracle with per-pair overrides
│
├── test/
│   ├── ILCalculator.t.sol            # 11 unit tests (incl. fuzz: IL never > 10000 bps)
│   ├── Integration.t.sol             # 11 end-to-end lifecycle tests
│   └── mocks/
│       ├── MockERC20.sol             # ERC20 with public mint/burn
│       ├── MockERC4626Vault.sol      # ERC4626 with simulateYield()
│       └── MockVolatilityOracle.sol  # Configurable regime (0–3)
│
├── script/
│   └── Deploy.s.sol                  # CREATE2 salt mining + full deployment
│
├── lib/
│   ├── v4-core/                      # Uniswap v4 core (git submodule)
│   └── forge-std/                    # Foundry test utilities (git submodule)
│
├── foundry.toml                      # solc 0.8.26, via_ir=true, optimizer
├── remappings.txt                    # v4-core/ → lib/v4-core/src/
└── PRD.md                            # Full product requirements document
```

---

## 10. Getting Started

### Prerequisites

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Verify
forge --version   # forge 0.2.0 or later
```

### Clone and Install

```bash
git clone <repo-url>
cd PremiumYield

# Initialize all submodules (v4-core, forge-std, solmate, openzeppelin-contracts)
git submodule update --init --recursive
```

### Build

```bash
forge build
```

> Note: the first build takes ~30 seconds due to `via_ir = true`. Subsequent builds are cached. This flag is required to avoid stack-too-deep errors in `beforeAddLiquidity`.

---

## 11. Running Tests

```bash
# Run all tests
forge test

# Verbose (traces on failure)
forge test -vvv

# Specific suites
forge test --match-contract ILCalculatorTest -vvv
forge test --match-contract IntegrationTest  -vvv

# Single test
forge test --match-test test_fullLifecycle_claimTriggered -vvv
```

### Test Coverage Summary

```
╭──────────────────────┬────────┬────────┬─────────╮
│ Test Suite           │ Passed │ Failed │ Skipped │
╞══════════════════════╪════════╪════════╪═════════╡
│ ILCalculatorTest     │ 11     │ 0      │ 0       │
│ IntegrationTest      │ 11     │ 0      │ 0       │
╰──────────────────────┴────────┴────────┴─────────╯
Total: 22 tests, 0 failures
```

### What Each Test Covers

**ILCalculator unit tests:**

| Test | Assertion |
|---|---|
| `test_noIL_samePrice` | Returns 0 bps when entry == exit |
| `test_IL_2xPriceMove` | √2 sqrtPrice ratio → ~572 bps |
| `test_IL_4xPriceMove` | 2× sqrtPrice ratio → 2000 bps |
| `test_IL_9xPriceMove` | 3× sqrtPrice ratio → 4000 bps |
| `test_IL_extremeMove` | 100× sqrtPrice ratio → >9700 bps |
| `test_IL_smallMove` | 0.1% move → ≤ 1 bps |
| `test_IL_symmetry` | Price up 4× == price down 4× |
| `test_IL_realSqrtPrices_10pctMove` | Real sqrtPriceX96 values, 10% price move → ~12 bps |
| `test_IL_neverExceedsBps (fuzz)` | Fuzz: IL ∈ [0, 10000] for all valid inputs |

**Integration tests:**

| Test | What It Proves |
|---|---|
| `test_premiumCollectedAndDeployedToVault` | Premium flows into vault; position recorded correctly |
| `test_noPremiumWhenOptedOut` | `wantsInsurance=false` skips all premium logic |
| `test_premiumScalesWithVolatilityRegime` | Elevated regime charges 2.5× Calm; measured via vault delta |
| `test_fullLifecycle_claimTriggered` | Large swap → significant IL → claim fires; position cleaned up |
| `test_fullLifecycle_noClaim_premiumReturned` | No price move → premium + yield returned to LP |
| `test_solvencyWarning` | `SolvencyWarning` event emitted when vault/liability < 120% |
| `test_depositsPausedAtLowSolvency` | Owner-paused pool rejects insured deposits; resume re-enables |
| `test_invalidThresholdReverts` | Threshold 0 and >5000 bps rejected with revert |
| `test_vaultGrowsWithMultipleLPs` | Sequential LP deposits each grow vault TVL |
| `test_vaultNotSetReverts` | Insured deposit on a pool with no vault registered reverts |
| `test_oracleFallbackToNormal` | Oracle returning Normal regime charges correct 1.5× premium |

---

## 12. Deployment

### Environment Variables

```bash
export POOL_MANAGER_ADDRESS=<v4-pool-manager-address>
export TOKEN0_ADDRESS=<lower-sorted-erc20>       # address(token0) < address(token1)
export TOKEN1_ADDRESS=<higher-sorted-erc20>
export VAULT_ADDRESS=<erc4626-vault>             # e.g., Aave aToken wrapper, Morpho vault
export RPC_URL=<node-rpc-endpoint>
export PRIVATE_KEY=<deployer-private-key>
export ETHERSCAN_KEY=<optional-for-verification>
```

### Deploy to Testnet

```bash
forge script script/Deploy.s.sol \
  --rpc-url $RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_KEY
```

The deployment script automatically:

1. Deploys `VolatilityOracle`
2. Mines a CREATE2 salt producing a hook address with the `0x901` bits set
3. Deploys `PremiumYieldHook` at that address
4. Registers the ERC4626 vault for the target pool

### Hook Address Requirement

Uniswap v4 uses the hook contract address as a permission bitmap. For PremiumYield, the lower 14 bits of the address must equal `0x901`:

```
Bit 11 (0x800): BEFORE_ADD_LIQUIDITY
Bit  8 (0x100): AFTER_REMOVE_LIQUIDITY
Bit  0 (0x001): AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA
                ─────
                0x901
```

The deploy script iterates salt values until `CREATE2Address(deployer, salt, initCodeHash) & 0x3FFF == 0x901`. This typically completes in < 160,000 iterations.

### Post-Deployment: Initialize Pool

```solidity
IPoolManager(POOL_MANAGER_ADDRESS).initialize(
    PoolKey({
        currency0:   Currency.wrap(TOKEN0_ADDRESS),
        currency1:   Currency.wrap(TOKEN1_ADDRESS),
        fee:         3000,          // 0.30% swap fee
        tickSpacing: 60,
        hooks:       IHooks(HOOK_ADDRESS)
    }),
    SQRT_PRICE_1_1  // = 79228162514264337593543950336 (1:1 starting price)
);
```

---

## 13. Demo Day Scenarios

### Act 1 — The Non-Claimer: Alice (price stays flat)

```
Setup:   Alice deposits 100 USDC / 0.05 ETH, 10% IL threshold, Normal volatility
Premium: ~7.5 bps of notional → goes to Aave vault immediately

Time passes. Vault earns 5% APY on Alice's premium.

Alice withdraws. Price moved <1% — IL is ~0.02%, far under her 10% threshold.

Result:  Hook returns premium + vault yield to Alice
         Alice earned a yield on her own insurance premium
         Net outcome: Alice is strictly better off than a plain LP position
```

### Act 2 — The Claimer: Bob (ETH price crashes 3×)

```
Setup:   Bob deposits with 5% IL threshold, Elevated volatility
Premium: ~12.5 bps of notional (2.5× regime multiplier)

ETH price drops 3×.
sqrtPrice ratio: 3× → realized IL = 4000 bps (40%)

Bob withdraws. IL > threshold (4000 bps > 500 bps).

Payout calculation:
  excess IL = 4000 - 500 = 3500 bps
  payout    = 3500 / 10000 × positionValue = 35% of position value

Hook redeems Bob's vault shares (premium + yield).
If payout > vault proceeds: capped at vault proceeds (Bob gets maximum available)
If payout < vault proceeds: surplus stays as fund reserves

Result:  Bob's loss is capped at his 5% threshold
         The vault covered the 35% excess IL
         Fund reserves grow from the remaining vault proceeds
```

### Act 3 — Vault Growth & Solvency Health

```
Five LPs deposit over two weeks.
Each premium enters the vault and begins earning yield.
Vault TVL grows from both new premiums and yield accrual.

solvencyRatio = vault.totalAssets() / totalCoverageLiability

Monitor sequence:
  - Start: ratio >> 120% (very healthy, only a few positions)
  - After many deposits with low thresholds: ratio approaches warning zone
  - At < 120%: SolvencyWarning event fires (off-chain monitoring picks this up)
  - At < 110%: new insured deposits auto-paused
  - As positions close (claim or refund): liability decreases, ratio recovers
  - Admin can resume deposits once ratio stabilizes above 110%
```

---

## Technical Notes

### Why no v4-periphery?

The project depends only on `v4-core`. The `IHooks` interface is implemented directly, eliminating the `BaseHook` abstraction. This reduces dependency surface and keeps the contract self-contained.

### Why `via_ir = true`?

`beforeAddLiquidity` has deep local variable usage — oracle calls, notional estimation, token transfers, vault interaction, and position writes all in one function body. The Solidity IR pipeline is required to avoid stack-too-deep compilation errors; it has no effect on runtime behavior.

### v4-core API Version Note

This implementation targets the current `v4-core` version where `ModifyLiquidityParams` and `SwapParams` are **standalone top-level types** in `v4-core/types/PoolOperation.sol`, not nested inside `IPoolManager`. Always import them as:

```solidity
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
```

---

## License

MIT

---

*Built for UHI9 Hookathon · Uniswap Hook Incubator Cohort 9 · May 25, 2026*
