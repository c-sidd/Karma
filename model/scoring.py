"""Turning a default probability into a Karma score, and a score into terms.

The mapping is the standard credit-scoring one: score is linear in the log odds
of *not* defaulting, anchored so that a fixed number of points always doubles
the odds. It is not a percentile rank, so a score means the same thing today as
it did last month even if the population shifts.

    score = BASE_SCORE + (PDO / ln 2) * ln(odds / BASE_ODDS)
    odds  = (1 - p_default) / p_default

Clipped to the [300, 900] range that ScoreOracle and RiskParams both enforce.

The anchors are a design choice, not a fit: 660 means 25:1 odds against default,
and every 50 points doubles those odds. They were chosen so the odds the model
can actually resolve span most of the range. A model that cannot distinguish
better than a few hundred to one will not hand out 900s, and that is the
correct behaviour rather than something to paper over.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping, Sequence

from . import MODEL_VERSION
from .features import FEATURE_NAMES, FEATURES, feature_hash, feature_vector
from .risk_curve import MAX_SCORE, MIN_SCORE, ratio_bps

#: Score at which the odds of not defaulting equal BASE_ODDS.
BASE_SCORE = 660
#: Odds of not defaulting at BASE_SCORE. 25:1 is a ~3.8% default rate.
BASE_ODDS = 25.0
#: Points to double the odds.
PDO = 50

#: Probabilities are clipped before taking odds so a confident model cannot
#: produce an infinite score.
P_FLOOR = 1e-4
P_CEIL = 1.0 - 1e-4


def probability_to_score(p_default: float) -> int:
    """Map a calibrated default probability to a 300-900 score."""
    p = min(max(float(p_default), P_FLOOR), P_CEIL)
    odds = (1.0 - p) / p
    raw = BASE_SCORE + (PDO / math.log(2.0)) * math.log(odds / BASE_ODDS)
    return int(min(max(round(raw), MIN_SCORE), MAX_SCORE))


def score_to_band(score: int) -> str:
    """The band label used in the report and the UI."""
    if score >= 900:
        return "900"
    return f"{(score // 100) * 100}-{(score // 100) * 100 + 99}"


@dataclass(frozen=True)
class ScoreBreakdown:
    """One feature's pull on a single wallet's score."""

    name: str
    value: float
    #: Score points attributable to this feature, positive or negative.
    contribution: float
    #: The population median this feature was compared against.
    baseline: float


@dataclass(frozen=True)
class ScoreResult:
    wallet: str
    score: int
    probability_of_default: float
    model_version: int
    feature_values: dict
    feature_hash: str
    collateral_ratio_bps: int
    breakdown: list


class KarmaModel:
    """A trained model plus everything needed to explain and sign one score."""

    def __init__(self, estimator, baselines: Sequence[float], model_version: int = MODEL_VERSION):
        self.estimator = estimator
        self.baselines = list(baselines)
        self.model_version = int(model_version)

    # ------------------------------------------------------------------ io

    @classmethod
    def load(cls, path: str | Path) -> "KarmaModel":
        import joblib

        blob = joblib.load(Path(path))
        return cls(blob["estimator"], blob["baselines"], blob["model_version"])

    def save(self, path: str | Path) -> None:
        import joblib

        Path(path).parent.mkdir(parents=True, exist_ok=True)
        joblib.dump(
            {
                "estimator": self.estimator,
                "baselines": self.baselines,
                "model_version": self.model_version,
                "feature_names": list(FEATURE_NAMES),
            },
            Path(path),
        )

    # -------------------------------------------------------------- scoring

    def probability(self, values: Sequence[float]) -> float:
        import numpy as np

        x = np.asarray([list(values)], dtype=float)
        return float(self.estimator.predict_proba(x)[0, 1])

    def score(self, wallet: str, row: Mapping[str, float]) -> ScoreResult:
        values = feature_vector(row)
        p = self.probability(values)
        score = probability_to_score(p)
        return ScoreResult(
            wallet=wallet,
            score=score,
            probability_of_default=p,
            model_version=self.model_version,
            feature_values=dict(zip(FEATURE_NAMES, values)),
            feature_hash="0x" + feature_hash(wallet, self.model_version, values).hex(),
            collateral_ratio_bps=ratio_bps(score),
            breakdown=[b.__dict__ for b in self.explain(values, score)],
        )

    # ------------------------------------------------------------ explaining

    def explain(self, values: Sequence[float], score: int | None = None) -> list[ScoreBreakdown]:
        """Per-feature contribution by leave-one-out ablation.

        For each feature, the model is re-run with that feature replaced by its
        training-set median and everything else held fixed. The contribution is
        the resulting change in score points.

        This is an honest, reproducible attribution, and it is not SHAP: the
        eight contributions do not sum exactly to the distance from the baseline
        score, because the model is not additive. They are directional
        magnitudes, and the report says so.
        """
        values = list(values)
        if score is None:
            score = probability_to_score(self.probability(values))

        out: list[ScoreBreakdown] = []
        for i, feature in enumerate(FEATURES):
            ablated = list(values)
            ablated[i] = self.baselines[i]
            ablated_score = probability_to_score(self.probability(ablated))
            out.append(
                ScoreBreakdown(
                    name=feature.name,
                    value=values[i],
                    contribution=float(score - ablated_score),
                    baseline=float(self.baselines[i]),
                )
            )
        return out
