// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title TestUSDC
/// @notice Testnet-only ERC-20 mimicking USDC with 6 decimals, a public faucet, and owner-only mint.
/// @dev Reverts on Polygon mainnet (chain ID 137) to prevent accidental deployment.
contract TestUSDC is ERC20, Ownable {
    uint8 private constant DECIMALS = 6;
    uint256 public constant FAUCET_WINDOW_LIMIT = 100_000 * 10 ** DECIMALS;
    uint256 public constant FAUCET_WINDOW = 24 hours;

    mapping(address recipient => uint256 start) public faucetWindowStart;
    mapping(address recipient => uint256 used) public faucetWindowUsed;

    error MainnetDeploymentBlocked();
    error FaucetWindowExceeded(uint256 requested, uint256 remaining);

    constructor(address initialOwner) ERC20("Test USD Coin", "USDC") Ownable(initialOwner) {
        if (block.chainid == 137) revert MainnetDeploymentBlocked();
    }

    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }

    /// @notice Owner-only mint for automation and operator use.
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Public faucet for testnet use. Rate-limited to 100,000 USDC cumulative per 24-hour window.
    /// @param to Recipient address.
    /// @param amount Amount to mint (up to remaining window allowance).
    function faucet(address to, uint256 amount) external {
        uint256 windowStart = faucetWindowStart[to];
        uint256 usedAmount = faucetWindowUsed[to];

        // Reset window if expired or first call
        if (windowStart == 0 || block.timestamp >= windowStart + FAUCET_WINDOW) {
            windowStart = block.timestamp;
            usedAmount = 0;
            faucetWindowStart[to] = windowStart;
        }

        uint256 remaining = FAUCET_WINDOW_LIMIT - usedAmount;
        if (amount > remaining) {
            revert FaucetWindowExceeded(amount, remaining);
        }

        faucetWindowUsed[to] = usedAmount + amount;
        _mint(to, amount);
    }
}
