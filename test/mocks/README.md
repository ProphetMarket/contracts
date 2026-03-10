---
module: mocks
purpose: Mock contracts for testing; provides a minimal Gnosis CTF implementation.
last-updated: 2026-03-10
---

# Test Mocks

Mock implementations of external contracts used by the test suite.

## Files

| File | Description |
|------|-------------|
| MockConditionalTokens.sol | ERC1155-based mock of Gnosis CTF; implements condition preparation, position splitting/merging, payout reporting, and redemption with ID computation matching the Gnosis spec |
| MockPolySafeFactory.sol | Minimal mock implementing `masterCopy()` for PolySafeLib address derivation in exchange tests; avoids cross-project compiler conflicts with the real SafeProxyFactory (solc 0.8.4) |

## MockConditionalTokens

Implements the `IConditionalTokens` interface from the CTF Exchange with real ID computation:

- `conditionId = keccak256(oracle, questionId, outcomeSlotCount)`
- `collectionId = keccak256(parentCollectionId, conditionId, indexSet)`
- `positionId = uint256(keccak256(collateralToken, collectionId))`

Key operations:
- `splitPosition` — Takes ERC20 collateral, mints ERC1155 position tokens
- `mergePositions` — Burns ERC1155 position tokens, returns ERC20 collateral
- `redeemPositions` — Burns winning positions, pays out proportional collateral

Not intended for production use.
