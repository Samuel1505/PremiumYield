// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IVolatilityOracle} from "../../src/interfaces/IVolatilityOracle.sol";

/// @notice Configurable volatility oracle for testing regime-scaling behavior
contract MockVolatilityOracle is IVolatilityOracle {
    uint8 public regime;
    uint256 public volBps;

    constructor(uint8 _regime, uint256 _volBps) {
        regime = _regime;
        volBps = _volBps;
    }

    function setRegime(uint8 _regime) external {
        regime = _regime;
    }

    function setVolBps(uint256 _volBps) external {
        volBps = _volBps;
    }

    function getCurrentRegime(address, address) external view override returns (uint8) {
        return regime;
    }

    function getAnnualizedVolBps(address, address) external view override returns (uint256) {
        return volBps;
    }
}
