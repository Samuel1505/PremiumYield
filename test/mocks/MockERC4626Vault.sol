// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Minimal ERC4626 vault backed by a MockERC20 underlying asset.
///         1:1 share-to-asset ratio by default; yield is injected via simulateYield().
///         For tests only.
contract MockERC4626Vault is IERC4626 {
    // ── ERC20 (share token) state ─────────────────────────────────────────
    string public override name = "MockVault";
    string public override symbol = "mvTOKEN";
    uint8 public decimals = 18;

    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    // ── ERC4626 state ─────────────────────────────────────────────────────
    address private immutable _asset;

    constructor(address asset_) {
        _asset = asset_;
    }

    // ── ERC20 implementation ──────────────────────────────────────────────

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        return _transfer(msg.sender, to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        return _transfer(from, to, amount);
    }

    function _transfer(address from, address to, uint256 amount) internal returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function _mint(address to, uint256 shares) internal {
        balanceOf[to] += shares;
        totalSupply += shares;
        emit Transfer(address(0), to, shares);
    }

    function _burn(address from, uint256 shares) internal {
        balanceOf[from] -= shares;
        totalSupply -= shares;
        emit Transfer(from, address(0), shares);
    }

    // ── ERC4626 implementation ────────────────────────────────────────────

    function asset() external view override returns (address) {
        return _asset;
    }

    function totalAssets() public view override returns (uint256) {
        return IERC20(_asset).balanceOf(address(this));
    }

    function convertToShares(uint256 assets) public view override returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) return assets;
        return (assets * supply) / totalAssets();
    }

    function convertToAssets(uint256 shares) public view override returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) return shares;
        return (shares * totalAssets()) / supply;
    }

    function maxDeposit(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function previewDeposit(uint256 assets) external view override returns (uint256) {
        return convertToShares(assets);
    }

    function deposit(uint256 assets, address receiver) external override returns (uint256 shares) {
        shares = convertToShares(assets);
        IERC20(_asset).transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function maxMint(address) external pure override returns (uint256) {
        return type(uint256).max;
    }

    function previewMint(uint256 shares) external view override returns (uint256) {
        return convertToAssets(shares);
    }

    function mint(uint256 shares, address receiver) external override returns (uint256 assets) {
        assets = convertToAssets(shares);
        IERC20(_asset).transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function maxWithdraw(address owner_) external view override returns (uint256) {
        return convertToAssets(balanceOf[owner_]);
    }

    function previewWithdraw(uint256 assets) external view override returns (uint256) {
        return convertToShares(assets);
    }

    function withdraw(uint256 assets, address receiver, address owner_) external override returns (uint256 shares) {
        shares = convertToShares(assets);
        _redeem(shares, assets, receiver, owner_);
    }

    function maxRedeem(address owner_) external view override returns (uint256) {
        return balanceOf[owner_];
    }

    function previewRedeem(uint256 shares) external view override returns (uint256) {
        return convertToAssets(shares);
    }

    function redeem(uint256 shares, address receiver, address owner_) external override returns (uint256 assets) {
        assets = convertToAssets(shares);
        _redeem(shares, assets, receiver, owner_);
    }

    function _redeem(uint256 shares, uint256 assets, address receiver, address owner_) internal {
        uint256 allowed = allowance[owner_][msg.sender];
        if (msg.sender != owner_ && allowed != type(uint256).max) {
            allowance[owner_][msg.sender] = allowed - shares;
        }
        _burn(owner_, shares);
        IERC20(_asset).transfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner_, assets, shares);
    }

    // ── Test helper ───────────────────────────────────────────────────────

    /// @notice Donate yield to the vault (simulates external yield accrual)
    function simulateYield(uint256 yieldAmount) external {
        MockERC20(_asset).mint(address(this), yieldAmount);
    }
}
