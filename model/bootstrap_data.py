"""SYNTHETIC fallback dataset. This is not real on-chain data.

Karma's real training data comes from Dune (see model/dune_queries.sql). That
query needs a free Dune account, so this generator exists to make the pipeline
runnable end to end from a clean checkout with no credentials.

Three deliberate guards keep the two apart:

  1. The output filename always contains "bootstrap".
  2. A sidecar .provenance.json is written alongside it with
     is_real_data=false, and model/dataset.py refuses to load any dataset that
     has no provenance sidecar.
  3. That provenance travels into model_report.json, into the saved model, out
     through the signer API, and onto a banner in the UI.

A number produced from this data describes a simulation, nothing more.
"""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import pandas as pd

from .features import FEATURE_NAMES

LABEL = "BOOTSTRAP - SYNTHETIC DATA, NOT REAL ON-CHAIN ACTIVITY"


def generate(n_rows: int = 20_000, seed: int = 20260820) -> pd.DataFrame:
    """Draw wallets from a latent-creditworthiness model.

    A single hidden variable z drives both the observable features and the
    default outcome, with independent noise on each so the model has to work
    for its AUC rather than reading z off any one column.
    """
    rng = np.random.default_rng(seed)

    # Latent creditworthiness. Higher is better.
    z = rng.normal(0.0, 1.0, n_rows)

    wallet_age_days = np.clip(
        rng.lognormal(mean=5.2 + 0.35 * z, sigma=0.7), 1, 3_600
    ).round()

    tx_count_90d = rng.poisson(np.exp(1.9 + 0.45 * z + rng.normal(0, 0.3, n_rows)))

    total_borrow_usd = np.clip(
        rng.lognormal(mean=8.6 + 0.55 * z, sigma=1.1), 50, 5_000_000
    ).round(2)

    # Repayment discipline: strong signal, but noisy and capped at 1.2 to allow
    # for interest paid on top of principal.
    repay_to_borrow_ratio = np.clip(
        0.72 + 0.16 * z + rng.normal(0, 0.13, n_rows), 0.0, 1.2
    ).round(6)

    liquidation_count = rng.poisson(np.clip(np.exp(-0.15 - 1.05 * z), 0, 12))

    max_leverage_ratio = np.clip(
        0.58 - 0.12 * z + rng.normal(0, 0.11, n_rows), 0.01, 0.98
    ).round(6)

    distinct_assets_borrowed = np.clip(
        rng.poisson(np.exp(0.55 + 0.3 * z)), 0, 25
    )

    avg_position_duration_days = np.clip(
        rng.lognormal(mean=2.1 + 0.42 * z, sigma=0.75), 0.05, 900
    ).round(3)

    # Outcome: liquidated within the forward 90-day window. Driven by z plus a
    # direct push from leverage and past liquidations, with enough logistic
    # noise that a perfect separator does not exist. The intercept is set so the
    # base rate lands near 7%, which is the order of magnitude Aave v3 borrowers
    # actually show over a 90-day window rather than a number chosen to flatter.
    logit = (
        -4.85
        - 1.55 * z
        + 1.25 * (max_leverage_ratio - 0.58)
        + 0.30 * np.minimum(liquidation_count, 6)
        - 0.85 * (repay_to_borrow_ratio - 0.72)
        + rng.normal(0, 0.55, n_rows)
    )
    p_default = 1.0 / (1.0 + np.exp(-logit))
    defaulted = (rng.random(n_rows) < p_default).astype(int)

    frame = pd.DataFrame(
        {
            "wallet_age_days": wallet_age_days,
            "tx_count_90d": tx_count_90d,
            "total_borrow_usd": total_borrow_usd,
            "repay_to_borrow_ratio": repay_to_borrow_ratio,
            "liquidation_count": liquidation_count,
            "max_leverage_ratio": max_leverage_ratio,
            "distinct_assets_borrowed": distinct_assets_borrowed,
            "avg_position_duration_days": avg_position_duration_days,
            "defaulted": defaulted,
        }
    )
    return frame[list(FEATURE_NAMES) + ["defaulted"]]


def provenance(path: Path, frame: pd.DataFrame, seed: int) -> dict:
    return {
        "kind": "bootstrap",
        "is_real_data": False,
        "label": LABEL,
        "generator": "model/bootstrap_data.py",
        "seed": seed,
        "n_rows": int(len(frame)),
        "default_rate": float(frame["defaulted"].mean()),
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "warning": (
            "Every metric derived from this file describes a simulation. It says "
            "nothing about real borrower behaviour."
        ),
    }


def write(out: Path, n_rows: int, seed: int) -> Path:
    if "bootstrap" not in out.name:
        raise ValueError("bootstrap output filename must contain 'bootstrap'")
    out.parent.mkdir(parents=True, exist_ok=True)
    frame = generate(n_rows, seed)
    frame.to_csv(out, index=False)
    side = out.with_suffix(out.suffix + ".provenance.json")
    side.write_text(json.dumps(provenance(out, frame, seed), indent=2) + "\n")
    return out


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--rows", type=int, default=40_000)
    p.add_argument("--seed", type=int, default=20260820)
    p.add_argument("--out", type=Path, default=Path("model/data/bootstrap_wallets_v1.csv"))
    args = p.parse_args(argv)

    out = write(args.out, args.rows, args.seed)
    frame = pd.read_csv(out)
    print(f"{LABEL}")
    print(f"wrote {out}  rows={len(frame)}  default_rate={frame['defaulted'].mean():.4f}")
    print(f"wrote {out.with_suffix(out.suffix + '.provenance.json')}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
