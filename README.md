# Karma

Credit-scored lending on Ethereum. A wallet's public repayment history is scored by a
gradient-boosted model; the contract prices that wallet's collateral requirement from the
score, on a line from 150% at the bottom of the range to 110% at the top.

**The point is not the model. The point is that the chain checks who produced the number.**

Most "AI plus smart contract" designs make the chain believe a value pushed by a script.
Karma's `ScoreOracle` recovers an ECDSA signature over
`(wallet, score, modelVersion, featureHash, expiry, nonce)`, bound by EIP-712 to the chain id
and to the oracle's own address, and reverts on anything not signed by a registered model
signer. `LendingPool.borrow()` has exactly one source of a score:

```solidity
uint16 score = scoreOracle.requireValidScore(msg.sender);
```

There is no owner override, no default score, and no branch that prices a loan when that call
reverts.

---

## Status

| Milestone | State |
|---|---|
| M1 — Contracts | 104 Solidity tests passing |
| M2 — Model pipeline | AUC 0.911, report emitted, bootstrap data labelled |
| M3 — Signer service | FastAPI, EIP-712 signing, cross-language test against the contract |
| M4 — Frontend | Next.js dashboard, verification panel, clean build |
| M5 — Docs | this file |

**Not deployed to Sepolia yet.** The deploy script is written and verified end to end against
a local anvil, but broadcasting to Sepolia needs a funded key that only you hold. See
[Deploying to Sepolia](#deploying-to-sepolia).

**The model is trained on synthetic data.** The real Dune query for Aave v3 is written and
documented in [`model/dune_queries.sql`](model/dune_queries.sql) but has never been executed,
because running it needs a Dune account. Every metric in this repository describes a
simulation, and the pipeline is built so that fact cannot be lost: see
[Bootstrap data](#bootstrap-data-and-why-it-cannot-be-mistaken-for-real-data).

---

## Architecture

```
                    off chain                    │                on chain
                                                 │
  ┌────────────┐   features    ┌──────────────┐  │   ┌───────────────────────────┐
  │  Chain     │──────────────▶│  Karma model │  │   │  Guardian                 │
  │  history   │               │  (sklearn)   │  │   │  owner, pause switch      │
  └────────────┘               └──────┬───────┘  │   └─────────────┬─────────────┘
                                      │          │                 │
                              score + featureHash│                 │ owner / paused
                                      ▼          │                 ▼
                              ┌──────────────┐   │   ┌───────────────────────────┐
                              │ signer svc   │   │   │  ScoreOracle              │
                              │ EIP-712 sign │───┼──▶│  ecrecover, nonce, expiry │
                              └──────────────┘   │   │  domain = chainid+address │
                                   calldata      │   └─────────────┬─────────────┘
                                      │          │                 │ requireValidScore
                                      ▼          │                 ▼
                              ┌──────────────┐   │   ┌───────────────────────────┐
                              │  frontend    │   │   │  LendingPool              │
                              │  wagmi/viem  │───┼──▶│  borrow priced by score   │
                              └──────────────┘   │   └─────────────┬─────────────┘
                                                 │                 │ collateralRatioBps
                                                 │                 ▼
                                                 │   ┌───────────────────────────┐
                                                 │   │  RiskParams               │
                                                 │   │  300→150%  900→110%       │
                                                 │   └───────────────────────────┘
```

### Contracts

| Contract | Responsibility |
|---|---|
| [`Guardian`](contracts/src/Guardian.sol) | One owner, two-step transfer, one protocol-wide pause. Any guardian can pause; only the owner can unpause. |
| [`ScoreOracle`](contracts/src/ScoreOracle.sol) | The only way a score enters the protocol. EIP-712 recovery, nonce, expiry, malleability and signer-registry checks. |
| [`RiskParams`](contracts/src/RiskParams.sol) | Score to collateral ratio, linear in integer arithmetic, endpoints governable but caged between 105% and 300%. |
| [`LendingPool`](contracts/src/LendingPool.sol) | Collateral, debt, interest, liquidation. Borrowing is gated on a live attestation. |
| [`StaticPriceOracle`](contracts/src/StaticPriceOracle.sol) | **Testnet only.** Owner-published prices, because Sepolia has no liquid markets to read. |
| [`FaucetToken`](contracts/src/testnet/FaucetToken.sol) | **Testnet only.** Freely mintable, worthless test assets. |

### Off chain

| Component | Responsibility |
|---|---|
| [`model/`](model/) | Feature definitions and canonical hashing, bootstrap data generator, training, evaluation report. |
| [`model/risk_curve.py`](model/risk_curve.py) | The Python twin of `RiskParams.sol`, pinned to it by a parity test at all 601 scores. |
| [`signer/`](signer/) | FastAPI service: score a wallet, sign the attestation, return the calldata. |
| [`web/`](web/) | Next.js dashboard. The verification panel is the product's argument made visible. |

---

## The signature scheme

```
digest = keccak256(0x1901 ‖ domainSeparator ‖ structHash)

domainSeparator = keccak256(abi.encode(
    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
    keccak256("Karma"), keccak256("1"), block.chainid, address(this)))

structHash = keccak256(abi.encode(
    keccak256("ScoreAttestation(address wallet,uint16 score,uint32 modelVersion,"
              "bytes32 featureHash,uint64 expiry,uint256 nonce)"),
    wallet, score, modelVersion, featureHash, expiry, nonce))
```

The typehash is a compile-time `keccak256` of its own string, never a pasted constant, and a
test asserts the two agree.

`featureHash` commits the signer to the exact feature vector that produced the score:

```
featureHash = keccak256(abi.encode(schemaHash, wallet, modelVersion, uint256[8] quantised))
```

The chain cannot recompute this — the inputs are not on chain in that form. It is a
commitment, not a proof, and the UI says so. What it buys you is that a signer cannot later
claim a different set of inputs produced the score they signed.

---

## Threat model

### What Karma defends against

| Attack | Defence | Test |
|---|---|---|
| Script pushes an unsigned score | No write path without recovery; no owner setter for a record | `test_noWriteWithoutSignature` |
| Forged signature from an unregistered key | `isModelSigner[recovered]` checked, reverts `BadSigner()` | `test_wrongSigner_reverts` |
| Borrower edits their own score upward | Any field change alters the digest, recovery yields another address | `test_tamperedScore_reverts`, `testFuzz_anyTamperedScore_reverts` |
| Borrower edits any other signed field | Same, per field | `test_tamperedWallet_reverts`, `test_tamperedFeatureHash_reverts`, `test_tamperedExpiry_reverts`, `test_tamperedModelVersion_reverts` |
| Replay a stale but genuine attestation | Per-wallet single-use nonce | `test_replayedNonce_reverts`, `test_replayedNonceAfterScoreDrop_reverts` |
| Signature malleability as a second bite | `s` forced into the lower half of the curve, `v` restricted to {27,28} | `test_malleableSignature_reverts`, `test_malleableSignature_cannotBypassNonce` |
| Replay onto another deployment | Domain binds `address(this)` | `test_crossContractReplay_reverts` |
| Replay onto another chain | Domain binds `block.chainid`, rebuilt if the chain id changes | `test_crossChainReplay_reverts` |
| Scores that never go stale | `expiry` enforced, capped at a 7-day TTL | `test_expiredAttestation_reverts`, `test_expiryBeyondMaxTtl_reverts` |
| Compromised model retired too slowly | `minModelVersion` invalidates stored records immediately | `test_retiringModelVersion_invalidatesStoredRecords` |
| Borrowing with no score at all | `requireValidScore` reverts; no fallback in `borrow()` | `test_borrowWithoutAttestation_reverts` |
| Withdrawing collateral once a score lapses | Health checks fall back to the *worst* ratio, never a permissive one | `test_withdrawWithExpiredScoreUsesWorstCaseRatio` |
| Governance quietly pricing below safe | Curve caged at `ABS_MIN_RATIO_BPS` | `test_setCurve_cannotBreachFloor`, `testFuzz_monotonicUnderAnyAdmissibleCurve` |

### What Karma does not defend against, and you should assume is broken

1. **A dishonest model signer.** Whoever holds the signing key can sign any score for any
   wallet. Karma proves *who* produced a number, never that the number is *correct*. In
   production this key belongs in an HSM or behind a threshold signature, and the mitigation
   available today is the audit trail: `featureHash` and `modelVersion` are in every signature.
2. **The price oracle.** `StaticPriceOracle` is owner-published prices. It is a trusted
   component sitting next to a trustless one, and it must be replaced with Chainlink feeds
   before this holds anything of value.
3. **Feature integrity.** Features are computed off chain from an indexer. A wallet that can
   pollute the indexer can influence its own score. The commitment binds the signer to the
   inputs, but nothing verifies the inputs describe reality.
4. **Sybil resistance.** Nothing stops a borrower splitting activity across fresh wallets —
   though a fresh wallet scores badly by construction, which is most of the point.
5. **Owner compromise.** The `Guardian` owner can register a new model signer. Two-step
   transfer and pause reduce the blast radius; they do not eliminate it.
6. **No lender-side accounting.** Liquidity is owner-funded. Depositor shares do not exist
   in this version, so there is no lender to protect yet.
7. **Not audited.** No third party has reviewed this code.

---

## Security checklist

Run through before any change ships.

- [ ] `make test` green — Solidity and Python
- [ ] `make parity` green — the Solidity and Python curves still agree at all 601 scores
- [ ] `make fixtures && make test-sol` — the Python signature still verifies on chain
- [ ] No new function writes a `Record` without going through `_recover`
- [ ] `borrow()` still reads its score only from `requireValidScore`
- [ ] Every new health check falls back to the *worst* ratio, never a permissive one
- [ ] New governable parameters are bounded, with a test that the bound holds
- [ ] `s <= secp256k1n/2` and `v in {27,28}` still enforced
- [ ] Domain still binds `block.chainid` and `address(this)`
- [ ] No secret in the repo: `git grep -nE "PRIVATE_KEY=0x[0-9a-fA-F]{64}"` returns nothing
- [ ] `npm audit` in `web/` reports zero vulnerabilities
- [ ] Frontend typechecks and builds with zero errors, no console errors on load
- [ ] Any synthetic data is still labelled in the filename, the report, and the UI

---

## Five-minute local setup

Prerequisites: **Foundry**, **Node 20+**, **Python 3.9+**. No accounts, no API keys, no card.

```bash
brew install foundry          # or: curl -L https://foundry.paradigm.xyz | bash && foundryup
git clone --recursive https://github.com/ChaitanyaGidwani/Karma.git
cd Karma
make setup                    # venv, python deps, train the model, npm install
```

Then four terminals, in order:

```bash
make anvil            # 1. local chain on :8545
```
```bash
make deploy-local     # 2. deploy + sync the frontend's addresses, then exits
```
```bash
make signer-local     # 3. signer service on :8000
```
```bash
make web              # 4. dashboard on :3000
```

Open <http://localhost:3000> and connect a browser wallet to the Anvil network
(RPC `http://127.0.0.1:8545`, chain id `31337`). Import anvil's first account — its private
key is printed in the `make anvil` banner — to get a funded test wallet.

Then, in the UI:

1. **Faucet** in the position panel, then **Approve** and **Deposit** collateral.
2. **Request signed score** in the verification panel.
3. **Verify against contract** — the digest the service computed and the digest the contract
   computes appear side by side, with the recovered signer and the registry check.
4. **Submit tampered attestation** — the same signature with the score changed to 900. The
   contract answers `BadSigner()`.
5. **Submit on chain**, then **Borrow**.

To run the whole thing without a browser:

```bash
.venv/bin/python -m signer.cli score 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --dry-run
```

`--dry-run` scores and hashes without ever reading the signing key.

---

## Testing

```bash
make test        # everything
make test-sol    # 104 Solidity tests
make test-py     # 80 Python tests
make parity      # Solidity and Python price all 601 scores identically
```

Three cross-checks are worth knowing about, because unit tests alone only prove that our code
agrees with our code:

- **Solidity ↔ Python curve parity.** `model/risk_curve.py` emits a fixture;
  `RiskParamsParity.t.sol` asserts the contract matches it at every score. Mutation-checked: a
  1 bps change to the Python constants fails the test.
- **Cross-language signatures.** `CrossLanguageSignature.t.sol` takes a signature produced by
  `eth-account` and runs it through the real submit path, including the raw calldata the
  service hands the frontend. EIP-712 binds the verifying contract, so both sides derive the
  same CREATE address from a fixed deployer at nonce 0.
- **`cast` as a third implementation.** The digest construction was checked against
  `cast wallet sign --data`, which shares no code with either side.

---

## Bootstrap data, and why it cannot be mistaken for real data

The model ships trained on generated wallets. Four guards keep that visible:

1. The filename must contain `bootstrap`, or the loader refuses it.
2. A provenance sidecar is mandatory — a dataset with no `.provenance.json` does not load at
   all, which is the state in which this mistake would otherwise happen.
3. `is_real_data: false` travels into `model_report.json`, out through the signer's `/health`
   and `/model-report`, and onto a banner in the UI.
4. The signer labels every feature `synthetic` or `chain`, per feature, so a synthesised
   number can never be presented as an observed one.

To train on real data: run [`model/dune_queries.sql`](model/dune_queries.sql) on Dune's free
tier, export the CSV, then

```bash
python -m model.dataset declare model/data/aave_v3_ethereum_2025.csv \
    --kind dune --query-url <permalink>
python -m model.train --data model/data/aave_v3_ethereum_2025.csv
```

### Current model report

Numbers from [`model/artifacts/model_report.json`](model/artifacts/model_report.json), on
40,000 generated wallets with a 7.18% base default rate.

| Metric | Value |
|---|---|
| AUC (test) | 0.9106 |
| AUC (train) | 0.9296 |
| KS | 0.6814 |
| Brier | 0.0463 |

| Band | Wallets | Default rate | Collateral |
|---|---:|---:|---:|
| 300–399 | 296 | 65.88% | 146.74% |
| 400–499 | 540 | 40.74% | 140.07% |
| 500–599 | 1,011 | 16.91% | 133.40% |
| 600–699 | 1,834 | 4.69% | 126.74% |
| 700–799 | 3,517 | 1.08% | 120.07% |
| 800–900 | 2,802 | 0.29% | 113.34% |

Default rate falls monotonically across every band. That property, not the AUC, is what makes
a score usable for pricing. Against a flat 150% protocol this frees **18.16%** of collateral,
which is **22.18%** more borrowing power on the same deposit.

---

## Deploying to Sepolia

Needs a Sepolia key with test ETH from a free faucet. Nothing here costs money.

```bash
cp .env.example .env
.venv/bin/python -m signer.cli keygen     # generates the model signer key
# put DEPLOYER_PRIVATE_KEY, MODEL_SIGNER_ADDRESS and MODEL_SIGNER_PRIVATE_KEY in .env
set -a && source .env && set +a
make deploy-sepolia
node scripts/sync-contracts.mjs           # point the frontend at the new addresses
```

Addresses land in `contracts/deployments/11155111.json`. `.env` is gitignored and no key is
ever written into the repository.

---

## Design notes

The dashboard is built as an instrument, not a landing page. Ink, paper and two greys; one
accent reserved for verification state; red and green only for a revert and a success.
Structure is carried by hairline rules and alignment rather than shadow, radius is 2px, and
the layout is a dense sticky rail against a wide working area.

Type is **IBM Plex Sans** and **IBM Plex Mono**. Plex was drawn for technical documentation
and instrument readouts: the sans is a slightly narrow grotesque with squared terminals, and
the mono carries true tabular figures with a slashed zero, which is what keeps a column of
hashes and balances aligned. The two are metrically related, so a mono number sits on the same
rhythm as the sans label beside it. Every number, address and hash is mono.

---

## Dependencies

Each one, and why.

| Dependency | Why |
|---|---|
| `forge-std` | Foundry's test and script library. The only Solidity dependency. |
| `numpy`, `pandas` | Feature matrix and CSV ingest. |
| `scikit-learn` | `GradientBoostingClassifier`, metrics, train/test split. |
| `joblib` | Model artifact serialisation. |
| `eth-account`, `eth-abi`, `eth-utils` | EIP-712 signing and ABI encoding, independent of our Solidity — which is what makes the cross-language test meaningful. |
| `fastapi`, `uvicorn`, `pydantic` | The signer service and validation at its boundary. |
| `httpx` | FastAPI's `TestClient` transport, and the optional Etherscan provider. |
| `pytest` | Python test runner. |
| `next`, `react` | Frontend framework. |
| `wagmi`, `viem` | Typed contract reads and wallet transport. |
| `@tanstack/react-query` | Required by wagmi; also caches chain reads. |

No CSS framework: the design brief rules out the template look, and plain CSS with custom
properties removes the argument entirely.

## Licence

MIT.
