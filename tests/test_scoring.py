import math

import pytest

from model.risk_curve import MAX_SCORE, MIN_SCORE
from model.scoring import BASE_ODDS, BASE_SCORE, PDO, probability_to_score, score_to_band


def test_base_anchor_holds():
    p_at_base = 1.0 / (1.0 + BASE_ODDS)
    assert probability_to_score(p_at_base) == BASE_SCORE


def test_pdo_doubles_the_odds():
    p_at_base = 1.0 / (1.0 + BASE_ODDS)
    p_double = 1.0 / (1.0 + 2 * BASE_ODDS)
    assert probability_to_score(p_double) - probability_to_score(p_at_base) == PDO


def test_monotone_decreasing_in_default_probability():
    previous = probability_to_score(1e-6)
    for p in [1e-5, 1e-4, 1e-3, 0.01, 0.05, 0.2, 0.5, 0.8, 0.99]:
        current = probability_to_score(p)
        assert current <= previous, f"score rose as risk rose at p={p}"
        previous = current


@pytest.mark.parametrize("p", [0.0, 1e-12, 0.5, 1 - 1e-12, 1.0])
def test_always_inside_the_contract_range(p):
    assert MIN_SCORE <= probability_to_score(p) <= MAX_SCORE


def test_extremes_clip_rather_than_explode():
    assert probability_to_score(0.0) == MAX_SCORE
    assert probability_to_score(1.0) == MIN_SCORE
    assert not math.isnan(float(probability_to_score(0.0)))


def test_band_labels():
    assert score_to_band(300) == "300-399"
    assert score_to_band(742) == "700-799"
    assert score_to_band(900) == "900"
