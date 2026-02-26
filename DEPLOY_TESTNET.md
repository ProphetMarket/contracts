# Testnet Deployment Guide (Polygon Amoy)

Step-by-step runbook for deploying Prophet contracts to Polygon Amoy testnet.

## Prerequisites

- Foundry installed (`forge`, `cast`)
- A Foundry keystore account with testnet POL for gas
- An Etherscan API key (works across all Etherscan-family explorers)

## Contracts Deployed

| Order | Contract | Description |
|-------|----------|-------------|
| 1 | TestUSDC | ERC-20 collateral token (6 decimals, mimics USDC) |
| 2 | MockConditionalTokens | ERC-1155 Gnosis CTF implementation for testnet |
| 3 | Resolution | AI oracle contract for binary payout outcomes |
| 4 | ProphetCTFExchange | Order matching and trading exchange |

## Steps

### 1. Set up RPC and verify connectivity

```bash
export RPC_URL="https://rpc-amoy.polygon.technology"
cast chain-id --rpc-url $RPC_URL
# Expected output: 80002
```

### 2. Verify wallet balance

```bash
# List available keystore accounts
cast wallet list

# Check balance (replace with your deployer address)
cast balance <DEPLOYER_ADDRESS> --rpc-url $RPC_URL --ether
```

You need testnet POL for gas. The full deployment costs ~0.41 POL.

Get testnet POL from the [Polygon Amoy faucet](https://faucet.polygon.technology/).

### 3. Deploy contracts

From the `contracts/` directory:

```bash
forge script script/Deploy.s.sol \
  --sig "run()" \
  --account <DEPLOYER_ADDRESS> \
  --sender <DEPLOYER_ADDRESS> \
  --rpc-url $RPC_URL \
  --broadcast
```

> **Note:** The `--sig "run()"` flag is required because the script has two `run` functions (one for CLI, one for tests). Without it, Forge errors with "Multiple functions with the same name".

> **Note:** The Exchange contract is slightly above the 24KB size limit. When prompted `Do you wish to continue? [y/n]`, type `y` — this is fine on testnet.

You will be prompted for your keystore password. On success, all 4 contract addresses will be printed.

### 4. Verify contracts on Polygonscan

Export your Etherscan API key (works for all Etherscan-family explorers):

```bash
export POLYGONSCAN_API_KEY="your-etherscan-api-key"
```

Verify each contract (replace addresses with your actual deployed addresses):

```bash
# TestUSDC
forge verify-contract <USDC_ADDRESS> src/TestUSDC.sol:TestUSDC \
  --chain-id 80002 \
  --verifier-url "https://api.etherscan.io/v2/api?chainid=80002" \
  --etherscan-api-key $POLYGONSCAN_API_KEY

# MockConditionalTokens
forge verify-contract <CTF_ADDRESS> test/mocks/MockConditionalTokens.sol:MockConditionalTokens \
  --chain-id 80002 \
  --verifier-url "https://api.etherscan.io/v2/api?chainid=80002" \
  --etherscan-api-key $POLYGONSCAN_API_KEY

# Resolution
forge verify-contract <RESOLUTION_ADDRESS> src/Resolution.sol:Resolution \
  --chain-id 80002 \
  --verifier-url "https://api.etherscan.io/v2/api?chainid=80002" \
  --etherscan-api-key $POLYGONSCAN_API_KEY

# ProphetCTFExchange (requires constructor args)
CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address,address,address,address)" "<USDC_ADDRESS>" "<CTF_ADDRESS>" "0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67" "0x29fcB43b46531BcA003ddC8FCB67FFE91900C762")

forge verify-contract <EXCHANGE_ADDRESS> src/ProphetCTFExchange.sol:ProphetCTFExchange \
  --chain-id 80002 \
  --verifier-url "https://api.etherscan.io/v2/api?chainid=80002" \
  --etherscan-api-key $POLYGONSCAN_API_KEY \
  --constructor-args $CONSTRUCTOR_ARGS
```

> **Note:** The `cast abi-encode` command must be on a single line — shell line breaks between addresses will cause parsing errors.

## Redeployment

If something goes wrong and you need to redeploy specific contracts, set env vars for the ones you want to **keep**, then re-run the script:

```bash
# Example: keep USDC and CTF, redeploy Resolution and Exchange
export DEPLOYED_USDC=0x...
export DEPLOYED_CTF=0x...

forge script script/Deploy.s.sol \
  --sig "run()" \
  --account <DEPLOYER_ADDRESS> \
  --sender <DEPLOYER_ADDRESS> \
  --rpc-url $RPC_URL \
  --broadcast
```

## Optional: Configure Exchange Roles

To register a separate operator or admin on the exchange during deployment:

```bash
export OPERATOR_ADDRESS=0x...
export ADMIN_ADDRESS=0x...
```

Set these before running the deploy script. The deployer automatically gets both roles regardless.
