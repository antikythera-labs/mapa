// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockUSDC
/// @notice Sepolia-only ERC-20 stand-in for USDC (6 decimals + open mint).
///         Mantle Sepolia has no canonical USDC (A0.5 verdict). Mainnet uses real
///         0x09Bc4E0D864854c6aFB6eB9A9cdF58aC190D0dF9 instead — this contract is NOT deployed there.
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") { }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Anyone can mint — testnet faucet semantics. DO NOT reuse this on mainnet.
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
