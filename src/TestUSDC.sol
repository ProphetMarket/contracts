// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title TestUSDC
/// @notice Testnet-only ERC-20 mimicking USDC with 6 decimals, a public faucet, and owner-only mint.
/// @dev Reverts on Polygon mainnet (chain ID 137) to prevent accidental deployment.
contract TestUSDC is ERC20, Ownable {
    uint8 private constant DECIMALS = 6;
    uint256 public constant FAUCET_MAX_AMOUNT = 100_000 * 10 ** DECIMALS;
    uint256 public constant FAUCET_COOLDOWN = 24 hours;

    mapping(address recipient => uint256 lastUsed) public lastFaucetTime;

    error MainnetDeploymentBlocked();
    error FaucetAmountExceedsMax(uint256 requested, uint256 max);
    error FaucetCooldownActive(uint256 availableAt);

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

    /// @notice Public faucet for testnet use. Caller-rate-limited to one call per 24 hours.
    /// @param to Recipient address.
    /// @param amount Amount to mint (max 100,000 USDC per call).
    function faucet(address to, uint256 amount) external {
        if (amount > FAUCET_MAX_AMOUNT) {
            revert FaucetAmountExceedsMax(amount, FAUCET_MAX_AMOUNT);
        }

        uint256 lastUsed = lastFaucetTime[to];
        if (lastUsed != 0) {
            uint256 availableAt = lastUsed + FAUCET_COOLDOWN;
            if (block.timestamp < availableAt) {
                revert FaucetCooldownActive(availableAt);
            }
        }

        lastFaucetTime[to] = block.timestamp;
        _mint(to, amount);
    }
}
