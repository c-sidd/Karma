import pytest

from model.features import (
    FEATURE_NAMES,
    FEATURES,
    feature_hash,
    feature_vector,
    quantise,
    schema_hash,
)

WALLET = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
VALUES = [420.0, 37.0, 125_000.0, 0.98, 0.0, 0.61, 4.0, 22.5]


def test_exactly_eight_features():
    assert len(FEATURES) == 8
    assert len(set(FEATURE_NAMES)) == 8


def test_hash_is_deterministic():
    assert feature_hash(WALLET, 1, VALUES) == feature_hash(WALLET, 1, VALUES)


def test_hash_is_address_case_insensitive():
    assert feature_hash(WALLET.lower(), 1, VALUES) == feature_hash(WALLET.upper()
                                                                  .replace("0X", "0x"), 1, VALUES)


def test_hash_changes_with_every_input():
    base = feature_hash(WALLET, 1, VALUES)
    assert feature_hash("0x" + "11" * 20, 1, VALUES) != base, "wallet must bind"
    assert feature_hash(WALLET, 2, VALUES) != base, "model version must bind"
    for i in range(len(VALUES)):
        bumped = list(VALUES)
        bumped[i] += 1
        assert feature_hash(WALLET, 1, bumped) != base, f"feature {i} must bind"


def test_quantisation_survives_a_round_trip_of_scale():
    q = quantise(VALUES)
    assert q[FEATURE_NAMES.index("repay_to_borrow_ratio")] == 980_000
    assert q[FEATURE_NAMES.index("wallet_age_days")] == 420


def test_negative_features_rejected():
    bad = list(VALUES)
    bad[0] = -1.0
    with pytest.raises(ValueError):
        quantise(bad)


def test_schema_hash_pins_the_feature_set():
    # A stable, known value: if the feature list changes, this test is meant to
    # fail loudly so the change is a decision rather than an accident.
    assert schema_hash().hex() == (
        "17242025902b5f596e5fe7a47c2dda277b8d5e62970a5ddeddc684a056a061f7"
    )


def test_feature_vector_requires_every_feature():
    with pytest.raises(KeyError):
        feature_vector({"wallet_age_days": 1})
