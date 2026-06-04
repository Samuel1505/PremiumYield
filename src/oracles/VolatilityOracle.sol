// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IVolatilityOracle} from "../interfaces/IVolatilityOracle.sol";

/// @title VolatilityOracle
/// @notice On-chain volatility regime oracle for PremiumYieldHook.
/// @dev In production, _getAnnualizedVolBps() would derive 24hr realized volatility from
///      a Chainlink vol feed or Uniswap v4 TWAP tick-history. For the demo it returns a
///      configurable default (30% annualized) that the owner can override per pair.
contract VolatilityOracle is IVolatilityOracle {
    // ── Regime thresholds (annualized vol in bps) ──────────────────────────
    uint256 public constant CALM_THRESHOLD = 2_000; // 20%
    uint256 public constant NORMAL_THRESHOLD = 5_000; // 50%
    uint256 public constant ELEVATED_THRESHOLD = 10_000; // 100%

    // Default regime when no override is set (regime 1 = Normal, 30% vol)
    uint256 public constant DEFAULT_VOL_BPS = 3_000;

    address public immutable owner;

    // Optional per-pair vol override (set by owner for the demo)
    // key: keccak256(abi.encodePacked(currency0, currency1))
    mapping(bytes32 => uint256) private _volOverride;

    event VolOverrideSet(address indexed currency0, address indexed currency1, uint256 volBps);

    error NotOwner();

    constructor() {
        owner = msg.sender;
    }

    // ── Owner configuration ────────────────────────────────────────────────

    /// @notice Set an annualized vol override for a specific currency pair (demo helper)
    function setVolOverride(address currency0, address currency1, uint256 volBps) external {
        if (msg.sender != owner) revert NotOwner();
        bytes32 key = _pairKey(currency0, currency1);
        _volOverride[key] = volBps;
        emit VolOverrideSet(currency0, currency1, volBps);
    }

    // ── IVolatilityOracle ─────────────────────────────────────────────────

    /// @inheritdoc IVolatilityOracle
    function getCurrentRegime(address currency0, address currency1) external view returns (uint8 regime) {
        uint256 vol = _getAnnualizedVolBps(currency0, currency1);
        if (vol < CALM_THRESHOLD) return 0;
        if (vol < NORMAL_THRESHOLD) return 1;
        if (vol < ELEVATED_THRESHOLD) return 2;
        return 3;
    }

    /// @inheritdoc IVolatilityOracle
    function getAnnualizedVolBps(address currency0, address currency1) external view returns (uint256) {
        return _getAnnualizedVolBps(currency0, currency1);
    }

    // ── Internal ──────────────────────────────────────────────────────────

    function _getAnnualizedVolBps(address currency0, address currency1) internal view returns (uint256) {
        bytes32 key = _pairKey(currency0, currency1);
        uint256 override_ = _volOverride[key];
        if (override_ != 0) return override_;
        // Fallback: default 30% vol (Normal regime).
        // Production implementation would query Chainlink vol feed or compute
        // from Uniswap v4 pool observations (log-return TWAP over 24h window).
        return DEFAULT_VOL_BPS;
    }

    function _pairKey(address currency0, address currency1) internal pure returns (bytes32) {
        // Sort addresses so (A,B) and (B,A) resolve to the same key
        (address a, address b) = currency0 < currency1 ? (currency0, currency1) : (currency1, currency0);
        return keccak256(abi.encodePacked(a, b));
    }
}
