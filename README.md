# contracts/

Smart contracts for Prophet's on-chain settlement system. Built with Foundry and OpenZeppelin v5.

## Directory Structure

```
contracts/
├── src/              # Contract source files
│   └── TestUSDC.sol  # Testnet USDC (ERC-20, 6 decimals, faucet)
├── test/             # Foundry test files
│   └── TestUSDC.t.sol
├── script/           # Deployment scripts
├── lib/              # Dependencies (forge-std, openzeppelin-contracts)
└── foundry.toml      # Foundry configuration
```

## Contracts

| Contract | Description | Network |
|----------|-------------|---------|
| TestUSDC | ERC-20 with 6 decimals, public faucet (100k cap, 24h cooldown), owner-only mint. Reverts on mainnet (chain 137). | Testnet only |

## Commands

```shell
forge build       # Compile contracts
forge test        # Run tests
forge test -vv    # Run tests with verbose output
forge fmt         # Format Solidity files
forge fmt --check # Check formatting without modifying
```

## Dependencies

- [OpenZeppelin Contracts v5.6.0](https://github.com/OpenZeppelin/openzeppelin-contracts) — ERC20, Ownable
- [forge-std](https://github.com/foundry-rs/forge-std) — Foundry testing library

## Last Updated

2026-02-25
