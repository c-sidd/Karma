"""The Python side of the Solidity/Python parity guarantee.

contracts/test/RiskParamsParity.t.sol asserts Solidity matches this fixture.
This asserts Python matches the same fixture. Together they pin both
implementations to one artifact rather than to each other.
"""

import json
from pathlib import Path

import pytest

from model.risk_curve import (
    ABS_MIN_RATIO_BPS,
    MAX_SCORE,
    MIN_SCORE,
    RATIO_AT_MAX_SCORE,
    RATIO_AT_MIN_SCORE,
    ScoreOutOfRange,
    liquidation_ratio_bps,
    ratio_bps,
)

FIXTURE = Path("contracts/test/fixtures/ratio_curve.json")


@pytest.fixture(scope="module")
def fixture():
    return json.loads(FIXTURE.read_text())


def test_fixture_constants_match_module(fixture):
    assert fixture["minScore"] == MIN_SCORE
    assert fixture["maxScore"] == MAX_SCORE
    assert fixture["ratioAtMinScore"] == RATIO_AT_MIN_SCORE
    assert fixture["ratioAtMaxScore"] == RATIO_AT_MAX_SCORE
    assert fixture["absMinRatioBps"] == ABS_MIN_RATIO_BPS


def test_every_score_matches_fixture(fixture):
    ratios = fixture["ratios"]
    liquidations = fixture["liquidationRatios"]
    assert len(ratios) == MAX_SCORE - MIN_SCORE + 1
    for score in range(MIN_SCORE, MAX_SCORE + 1):
        assert ratio_bps(score) == ratios[score - MIN_SCORE], f"ratio drift at {score}"
        assert (
            liquidation_ratio_bps(score) == liquidations[score - MIN_SCORE]
        ), f"liquidation drift at {score}"


def test_endpoints():
    assert ratio_bps(300) == 15_000
    assert ratio_bps(900) == 11_000


def test_monotone_non_increasing():
    previous = ratio_bps(MIN_SCORE)
    for score in range(MIN_SCORE + 1, MAX_SCORE + 1):
        current = ratio_bps(score)
        assert current <= previous, f"curve rose at {score}"
        previous = current


def test_out_of_range_rejected():
    with pytest.raises(ScoreOutOfRange):
        ratio_bps(299)
    with pytest.raises(ScoreOutOfRange):
        ratio_bps(901)


def test_bool_is_not_an_int_here():
    # True == 1 in Python; silently scoring a bool would be a real bug.
    with pytest.raises(TypeError):
        ratio_bps(True)
