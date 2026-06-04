// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";

import {PremiumYieldHook} from "../src/PremiumYieldHook.sol";
import {VolatilityOracle} from "../src/oracles/VolatilityOracle.sol";
import {IVolatilityOracle} from "../src/interfaces/IVolatilityOracle.sol";

/// @notice Deployment script for PremiumYield on a network with an existing PoolManager.
///
/// Required env variables:
///   POOL_MANAGER_ADDRESS  — deployed Uniswap v4 PoolManager
///   TOKEN0_ADDRESS        — lower-sorted ERC20 address
///   TOKEN1_ADDRESS        — higher-sorted ERC20 address
///   VAULT_ADDRESS         — ERC4626 vault address (e.g. Aave aToken wrapper)
///
/// Usage:
///   forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify
contract DeployScript is Script {
    using PoolIdLibrary for PoolKey;

    // Hook flag combination required in the deployed address
    uint160 constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            | Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG
    );

    function run() external {
        address poolManagerAddr = vm.envAddress("POOL_MANAGER_ADDRESS");
        address token0Addr = vm.envAddress("TOKEN0_ADDRESS");
        address token1Addr = vm.envAddress("TOKEN1_ADDRESS");
        address vaultAddr = vm.envAddress("VAULT_ADDRESS");

        // Ensure tokens are sorted
        require(token0Addr < token1Addr, "TOKEN0 must be < TOKEN1 by address");

        vm.startBroadcast();

        // 1. Deploy VolatilityOracle
        VolatilityOracle volOracle = new VolatilityOracle();
        console2.log("VolatilityOracle deployed at:", address(volOracle));

        // 2. Mine a hook address with the required flags
        //    Using CREATE2: try salts until we find an address with the right bits
        address hookAddress = _mineHookAddress(poolManagerAddr, address(volOracle));
        console2.log("Hook address (pre-mined):", hookAddress);

        // 3. Deploy hook at the mined address using CREATE2
        bytes32 salt = _findSalt(poolManagerAddr, address(volOracle));
        PremiumYieldHook hookImpl =
            new PremiumYieldHook{salt: salt}(IPoolManager(poolManagerAddr), IVolatilityOracle(address(volOracle)));
        require(address(hookImpl) == hookAddress, "Hook deployed at wrong address");
        console2.log("PremiumYieldHook deployed at:", address(hookImpl));

        // 4. Register vault for the pool
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0Addr),
            currency1: Currency.wrap(token1Addr),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });
        bytes32 pid = PoolId.unwrap(key.toId());
        hookImpl.setPoolVault(pid, vaultAddr);
        console2.log("Vault registered for pool:", vaultAddr);

        vm.stopBroadcast();

        console2.log("\n=== Deployment Summary ===");
        console2.log("PoolManager:       ", poolManagerAddr);
        console2.log("VolatilityOracle:  ", address(volOracle));
        console2.log("PremiumYieldHook:  ", address(hookImpl));
        console2.log("Vault:             ", vaultAddr);
        console2.log("Pool ID:           ");
        console2.logBytes32(pid);
        console2.log("\nNext step: initialize the pool if not already done:");
        console2.log("  IPoolManager(POOL_MANAGER).initialize(key, SQRT_PRICE_1_1)");
    }

    // ── Internal salt mining ──────────────────────────────────────────────

    function _mineHookAddress(address pm, address oracle) internal view returns (address) {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(PremiumYieldHook).creationCode, abi.encode(IPoolManager(pm), IVolatilityOracle(oracle))
            )
        );
        for (uint256 salt = 0; salt < 160_000; salt++) {
            address predicted = _computeCreate2Address(bytes32(salt), initCodeHash);
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS) {
                return predicted;
            }
        }
        revert("Could not find valid hook salt in 160k tries");
    }

    function _findSalt(address pm, address oracle) internal view returns (bytes32) {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(
                type(PremiumYieldHook).creationCode, abi.encode(IPoolManager(pm), IVolatilityOracle(oracle))
            )
        );
        for (uint256 salt = 0; salt < 160_000; salt++) {
            address predicted = _computeCreate2Address(bytes32(salt), initCodeHash);
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS) {
                return bytes32(salt);
            }
        }
        revert("Could not find valid hook salt");
    }

    function _computeCreate2Address(bytes32 salt, bytes32 initCodeHash) internal view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash)))));
    }
}
