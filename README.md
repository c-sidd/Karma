# Karma

Credit-scored lending on Ethereum. A wallet's public repayment history is scored by an
ML model; the contract prices that wallet's collateral requirement from the score,
between 150% at the bottom of the range and 110% at the top.

The point of the design is not the model. It is that **the chain checks who produced the
number**. `ScoreOracle` recovers an ECDSA signature over
`(wallet, score, modelVersion, featureHash, expiry, nonce)`, bound to the chain id and to
its own address, and reverts on anything not signed by a registered model signer.
`LendingPool.borrow()` has no code path that prices a loan from an unverified model output.

## Status

| Milestone | State |
|---|---|
| M1 — Contracts, hardened | done: 95 tests passing |
| M2 — Model pipeline | not started |
| M3 — Signer service | not started |
| M4 — Frontend | not started |
| M5 — Docs | not started |

Full documentation, threat model and setup guide land in M5.

## Layout

```
contracts/    Foundry project: src/, test/, script/
model/        risk_curve.py — canonical Python twin of RiskParams.sol
```

## Quick start

```bash
brew install foundry          # or: curl -L https://foundry.paradigm.xyz | bash
make test                     # regenerates the parity fixture, then runs everything
```

## Deploying to Sepolia

```bash
cp .env.example .env          # fill in DEPLOYER_PRIVATE_KEY and MODEL_SIGNER_ADDRESS
set -a && source .env && set +a
make deploy-sepolia
```

Addresses are written to `contracts/deployments/<chainId>.json`.
