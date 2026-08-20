"""Train the Karma credit model and write model_report.json.

    python -m model.train                      # uses the labelled bootstrap data
    python -m model.train --data model/data/aave_v3_ethereum_2025.csv

The report is the artefact that matters. AUC alone says a model ranks well; it
says nothing about whether the score is worth lending against. So the report
also carries the realised default rate in every score band, which is what shows
the score is monotone in risk, and the capital efficiency lift, which is what
shows the whole exercise buys the borrower something.
"""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.ensemble import GradientBoostingClassifier
from sklearn.metrics import brier_score_loss, roc_auc_score, roc_curve
from sklearn.model_selection import train_test_split

from . import MODEL_VERSION
from .dataset import LABEL_COLUMN, load
from .features import FEATURE_NAMES, describe
from .risk_curve import RATIO_AT_MIN_SCORE, ratio_bps
from .scoring import KarmaModel, probability_to_score

DEFAULT_DATA = Path("model/data/bootstrap_wallets_v1.csv")
DEFAULT_MODEL = Path("model/artifacts/karma_model.joblib")
DEFAULT_REPORT = Path("model/artifacts/model_report.json")


def ks_statistic(y_true: np.ndarray, y_score: np.ndarray) -> float:
    fpr, tpr, _ = roc_curve(y_true, y_score)
    return float(np.max(tpr - fpr))


def calibration_table(y_true: np.ndarray, p: np.ndarray, n_bins: int = 10) -> list[dict]:
    """Predicted vs observed default rate by predicted-risk decile.

    The score mapping reads the probability as a probability, so the
    probabilities have to be roughly right and not merely well ordered. This is
    the evidence for that, and it is in the report so the claim can be checked
    rather than taken on trust.
    """
    order = np.argsort(p)
    chunks = np.array_split(order, n_bins)
    rows = []
    for i, idx in enumerate(chunks):
        rows.append(
            {
                "decile": i + 1,
                "n": int(len(idx)),
                "mean_predicted": round(float(p[idx].mean()), 5),
                "observed": round(float(y_true[idx].mean()), 5),
            }
        )
    return rows


def score_band_table(scores: np.ndarray, y_true: np.ndarray) -> list[dict]:
    """Realised default rate per 100-point band, with the terms each band buys."""
    rows: list[dict] = []
    edges = [(300, 399), (400, 499), (500, 599), (600, 699), (700, 799), (800, 900)]
    for lo, hi in edges:
        mask = (scores >= lo) & (scores <= hi)
        n = int(mask.sum())
        rows.append(
            {
                "band": f"{lo}-{hi}",
                "n": n,
                "share_of_population": round(float(n / len(scores)), 4) if len(scores) else 0.0,
                "default_rate": round(float(y_true[mask].mean()), 4) if n else None,
                "collateral_ratio_bps": ratio_bps(int((lo + hi) // 2)),
            }
        )
    return rows


def capital_efficiency(scores: np.ndarray) -> dict:
    """How much collateral the score frees versus a flat 150% protocol."""
    ratios = np.array([ratio_bps(int(s)) for s in scores], dtype=float)
    weighted = float(ratios.mean())
    return {
        "baseline_ratio_bps": RATIO_AT_MIN_SCORE,
        "baseline_note": "Every borrower posts 150%, which is roughly where Aave v3 sits.",
        "mean_ratio_bps": round(weighted, 2),
        "median_ratio_bps": float(np.median(ratios)),
        "collateral_freed_pct": round(
            float((RATIO_AT_MIN_SCORE - weighted) / RATIO_AT_MIN_SCORE * 100.0), 2
        ),
        "borrowing_power_lift_pct": round(
            float((RATIO_AT_MIN_SCORE / weighted - 1.0) * 100.0), 2
        ),
    }


def monotonicity(bands: list[dict]) -> dict:
    """Does default rate actually fall as score rises? A model that ranks well
    can still produce a non-monotone band table, and that would make the score
    unusable for pricing even at a good AUC."""
    observed = [(b["band"], b["default_rate"]) for b in bands if b["default_rate"] is not None]
    rates = [r for _, r in observed]
    breaks = [
        f"{observed[i][0]} -> {observed[i + 1][0]}"
        for i in range(len(rates) - 1)
        if rates[i + 1] > rates[i]
    ]
    return {
        "is_monotone_decreasing": len(breaks) == 0,
        "bands_compared": len(rates),
        "violations": breaks,
    }


def train(
    data_path: Path, test_size: float, seed: int, model_version: int
) -> tuple[KarmaModel, dict]:
    frame, provenance = load(data_path)

    x = frame[list(FEATURE_NAMES)].to_numpy(dtype=float)
    y = frame[LABEL_COLUMN].to_numpy(dtype=int)

    x_train, x_test, y_train, y_test = train_test_split(
        x, y, test_size=test_size, random_state=seed, stratify=y
    )

    # Gradient boosting on log-loss, used directly rather than wrapped in
    # CalibratedClassifierCV. Both sigmoid and isotonic calibration were measured
    # on this data: sigmoid moved AUC by 0.001 while emitting overflow warnings
    # from its internal solver, and isotonic produced exact zero probabilities,
    # which collapses the whole good tail onto a single clipped score. The raw
    # log-loss probabilities are what the score mapping reads, so the report
    # carries a decile calibration table as the evidence they are usable.
    estimator = GradientBoostingClassifier(
        n_estimators=300,
        learning_rate=0.05,
        max_depth=3,
        subsample=0.9,
        random_state=seed,
    )
    estimator.fit(x_train, y_train)

    baselines = np.median(x_train, axis=0).tolist()
    model = KarmaModel(estimator, baselines, model_version)

    p_train = estimator.predict_proba(x_train)[:, 1]
    p_test = estimator.predict_proba(x_test)[:, 1]
    scores_test = np.array([probability_to_score(p) for p in p_test])

    bands = score_band_table(scores_test, y_test)

    importances = estimator.feature_importances_

    report = {
        "model_version": model_version,
        "trained_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "algorithm": "GradientBoostingClassifier (log-loss), probabilities used uncalibrated",
        "hyperparameters": {
            "n_estimators": 300,
            "learning_rate": 0.05,
            "max_depth": 3,
            "subsample": 0.9,
            "random_state": seed,
        },
        "data_source": provenance,
        "dataset": {
            "n_total": int(len(frame)),
            "n_train": int(len(x_train)),
            "n_test": int(len(x_test)),
            "base_default_rate": round(float(y.mean()), 4),
            "test_size": test_size,
        },
        "metrics": {
            "auc_test": round(float(roc_auc_score(y_test, p_test)), 4),
            "auc_train": round(float(roc_auc_score(y_train, p_train)), 4),
            "ks_test": round(ks_statistic(y_test, p_test), 4),
            "brier_test": round(float(brier_score_loss(y_test, p_test)), 5),
        },
        "score_distribution": {
            "min": int(scores_test.min()),
            "p25": int(np.percentile(scores_test, 25)),
            "median": int(np.median(scores_test)),
            "p75": int(np.percentile(scores_test, 75)),
            "max": int(scores_test.max()),
        },
        "score_bands": bands,
        "calibration_check": calibration_table(y_test, p_test),
        "band_monotonicity": monotonicity(bands),
        "capital_efficiency": capital_efficiency(scores_test),
        "features": describe(),
        "feature_importance": [
            {"name": n, "importance": round(float(v), 4)}
            for n, v in sorted(
                zip(FEATURE_NAMES, importances), key=lambda kv: kv[1], reverse=True
            )
        ],
        "explanation_method": {
            "kind": "leave-one-out ablation against the training median",
            "note": (
                "Per-wallet contributions are the score change from replacing one "
                "feature with its training median. They are directional and "
                "reproducible; they are not SHAP values and do not sum exactly to "
                "the distance from the baseline score."
            ),
        },
    }
    return model, report


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--data", type=Path, default=DEFAULT_DATA)
    p.add_argument("--out-model", type=Path, default=DEFAULT_MODEL)
    p.add_argument("--out-report", type=Path, default=DEFAULT_REPORT)
    p.add_argument("--test-size", type=float, default=0.25)
    p.add_argument("--seed", type=int, default=20260820)
    p.add_argument("--model-version", type=int, default=MODEL_VERSION)
    args = p.parse_args(argv)

    model, report = train(args.data, args.test_size, args.seed, args.model_version)

    model.save(args.out_model)
    args.out_report.parent.mkdir(parents=True, exist_ok=True)
    args.out_report.write_text(json.dumps(report, indent=2) + "\n")

    src = report["data_source"]
    print("=" * 72)
    if not src.get("is_real_data"):
        print(f"  {src['label']}")
        print("  Metrics below describe a simulation, not real borrower behaviour.")
    else:
        print(f"  {src['label']}  ({src.get('query_url')})")
    print("=" * 72)
    m = report["metrics"]
    print(f"  AUC (test)        {m['auc_test']}")
    print(f"  AUC (train)       {m['auc_train']}")
    print(f"  KS  (test)        {m['ks_test']}")
    print(f"  Brier (test)      {m['brier_test']}")
    print(f"  base default rate {report['dataset']['base_default_rate']}")
    print()
    print("  band       n      default rate   collateral")
    for b in report["score_bands"]:
        rate = "  -   " if b["default_rate"] is None else f"{b['default_rate']:.4f}"
        print(f"  {b['band']:<9} {b['n']:<6} {rate:^14} {b['collateral_ratio_bps'] / 100:.2f}%")
    mono = report["band_monotonicity"]
    print(f"\n  monotone decreasing: {mono['is_monotone_decreasing']}  {mono['violations'] or ''}")
    ce = report["capital_efficiency"]
    print(
        f"  capital freed vs flat 150%: {ce['collateral_freed_pct']}%"
        f"  (borrowing power +{ce['borrowing_power_lift_pct']}%)"
    )
    print(f"\n  wrote {args.out_model}")
    print(f"  wrote {args.out_report}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
