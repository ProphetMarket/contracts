---
module: test
purpose: Foundry test suite for Prophet's on-chain contracts.
last-updated: 2026-02-25
---

# Test Suite

Foundry tests covering deployment, order matching, token operations, access control, and market resolution.

## Files

| File | Description |
|------|-------------|
| CTFExchange.t.sol | 21 tests: deployment config, fillOrder (buy/sell/partial), matchOrders (complementary/mint/merge), access control, expiration, pause, cancel, signature types |
| TestUSDC.t.sol | 21 tests: mint, faucet (limits + cooldown), mainnet guard, ERC-20 transfers, fuzz |
| Resolution.t.sol | 29 tests: oracle payouts, payout validation, role transfer, authorization, fuzz |
| mocks/ | Mock contracts for testing (see mocks/README.md) |

## Running Tests

```bash
forge test           # All tests
forge test -vvv      # With traces
forge test --match-contract CTFExchangeTest  # Single suite
```

## Test Actors

CTFExchange tests use deterministic keys via `makeAddrAndKey()`:
- **admin** — Deploys contracts, manages roles, acts as oracle
- **operator** — Fills and matches orders (the Prophet relayer)
- **alice / bob** — Market participants who sign orders
