---
module: test
purpose: Foundry test suite for Prophet's on-chain contracts.
last-updated: 2026-03-10
---

# Test Suite

Foundry tests covering deployment, order matching, token operations, access control, and market resolution.

## Files

| File | Description |
|------|-------------|
| CTFExchange.t.sol | 27 tests: deployment config, fillOrder (buy/sell/partial), matchOrders (complementary/mint/merge), access control (registerToken dual-role, admin-only functions), expiration, pause, cancel, signature types |
| TestUSDC.t.sol | 21 tests: mint, faucet (limits + cooldown), mainnet guard, ERC-20 transfers, fuzz |
| Resolution.t.sol | 29 tests: oracle payouts, payout validation, role transfer, authorization, fuzz |
| Deploy.t.sol | 15 tests: fresh deployment, mainnet guard, idempotency (skip pre-deployed contracts), operator/admin configuration, exchange initialization |
| AddOperator.t.sol | 4 tests: operator registration, idempotency, zero-address validation |
| PolyGnosisSafeMatch.t.sol | 4 tests: matchOrders with signatureType=POLY_GNOSIS_SAFE (buy/sell), invalid signature revert, wrong Safe maker revert |
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
