"""End-to-end checks on the trained artifact the signer service will load."""

import json
from pathlib import Path

import pytest

from model.features import FEATURE_NAMES, feature_hash
from model.risk_curve import ratio_bps
from model.scoring import KarmaModel

MODEL_PATH = Path("model/artifacts/karma_model.joblib")
REPORT_PATH = Path("model/artifacts/model_report.json")

GOOD_WALLET = {
    "wallet_age_days": 1200,
    "tx_count_90d": 90,
    "total_borrow_usd": 400_000,
    "repay_to_borrow_ratio": 1.05,
    "liquidation_count": 0,
    "max_leverage_ratio": 0.35,
    "distinct_assets_borrowed": 6,
    "avg_position_duration_days": 60.0,
}
BAD_WALLET = {
    "wallet_age_days": 25,
    "tx_count_90d": 4,
    "total_borrow_usd": 900,
    "repay_to_borrow_ratio": 0.30,
    "liquidation_count": 5,
    "max_leverage_ratio": 0.94,
    "distinct_assets_borrowed": 1,
    "avg_position_duration_days": 1.5,
}
ADDRESS = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"


@pytest.fixture(scope="module")
def model():
    if not MODEL_PATH.exists():
        pytest.skip("model not trained yet: run `make model`")
    return KarmaModel.load(MODEL_PATH)


@pytest.fixture(scope="module")
def report():
    return json.loads(REPORT_PATH.read_text())


def test_a_clean_history_outscores_a_liquidated_one(model):
    good = model.score(ADDRESS, GOOD_WALLET)
    bad = model.score(ADDRESS, BAD_WALLET)
    assert good.score > bad.score, "the model has the sign of credit risk backwards"
    assert good.collateral_ratio_bps < bad.collateral_ratio_bps


def test_score_is_inside_the_contract_range(model):
    for row in (GOOD_WALLET, BAD_WALLET):
        result = model.score(ADDRESS, row)
        assert 300 <= result.score <= 900


def test_ratio_matches_the_shared_curve(model):
    result = model.score(ADDRESS, GOOD_WALLET)
    assert result.collateral_ratio_bps == ratio_bps(result.score)


def test_feature_hash_is_reproducible_from_the_reported_values(model):
    result = model.score(ADDRESS, GOOD_WALLET)
    values = [result.feature_values[name] for name in FEATURE_NAMES]
    recomputed = "0x" + feature_hash(ADDRESS, result.model_version, values).hex()
    assert result.feature_hash == recomputed, "a verifier could not reproduce the hash"


def test_scoring_is_deterministic(model):
    first = model.score(ADDRESS, GOOD_WALLET)
    second = model.score(ADDRESS, GOOD_WALLET)
    assert (first.score, first.feature_hash) == (second.score, second.feature_hash)


def test_breakdown_covers_every_feature(model):
    result = model.score(ADDRESS, BAD_WALLET)
    assert [b["name"] for b in result.breakdown] == list(FEATURE_NAMES)
    assert any(b["contribution"] != 0 for b in result.breakdown), "no feature moved the score"


def test_liquidations_pull_a_score_down(model):
    clean = dict(GOOD_WALLET, liquidation_count=0)
    burned = dict(GOOD_WALLET, liquidation_count=4)
    assert model.score(ADDRESS, burned).score < model.score(ADDRESS, clean).score


# ------------------------------------------------------------------- report


def test_report_declares_its_data_source(report):
    src = report["data_source"]
    assert "is_real_data" in src and "label" in src
    if not src["is_real_data"]:
        assert "BOOTSTRAP" in src["label"]


def test_report_carries_the_metrics_the_brief_asks_for(report):
    assert report["metrics"]["auc_test"] > 0.5
    assert len(report["score_bands"]) == 6
    assert "collateral_freed_pct" in report["capital_efficiency"]


def test_default_rate_falls_as_score_rises(report):
    assert report["band_monotonicity"]["is_monotone_decreasing"], report["band_monotonicity"]


def test_every_band_is_reachable(report):
    empty = [b["band"] for b in report["score_bands"] if b["n"] == 0]
    assert not empty, f"unreachable score bands: {empty}"


def test_report_lists_all_eight_features(report):
    assert [f["name"] for f in report["features"]] == list(FEATURE_NAMES)
    assert len(report["feature_importance"]) == 8
