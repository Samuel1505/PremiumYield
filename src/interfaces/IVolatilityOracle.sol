// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IVolatilityOracle
/// @notice Interface for the volatility regime oracle used by PremiumYieldHook
interface IVolatilityOracle {
    /// @notice Returns the current volatility regime for a currency pair
    /// @param currency0 The first currency address
    /// @param currency1 The second currency address
    /// @return regime 0=Calm (<20%), 1=Normal (20-50%), 2=Elevated (50-100%), 3=Extreme (≥100%)
    function getCurrentRegime(address currency0, address currency1) external view returns (uint8 regime);

    /// @notice Returns the current annualized volatility in basis points
    /// @param currency0 The first currency address
    /// @param currency1 The second currency address
    /// @return volBps Annualized volatility in bps (e.g. 3000 = 30%)
    function getAnnualizedVolBps(address currency0, address currency1) external view returns (uint256 volBps);
}
