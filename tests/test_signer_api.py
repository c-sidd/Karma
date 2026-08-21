"""The signer service's HTTP surface.

The most important assertion in this file is the negative one: no response, at
any endpoint, in any state, contains the private key.
"""

import pytest
from eth_account import Account
from fastapi.testclient import TestClient

from signer.app import create_app
from signer.attestation import build, recover
from signer.config import Settings

# anvil development account #1: public, secures nothing.
PK = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
SIGNER = Account.from_key(PK).address
ORACLE = "0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0"
WALLET = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
OTHER = "0x90F79bf6EB2c4f870365E785982E1f101E93b906"


def _settings(**kw) -> Settings:
    base = dict(chain_id=31337, score_oracle_address=ORACLE, _private_key=PK)
    base.update(kw)
    return Settings(**base)


@pytest.fixture()
def client():
    return TestClient(create_app(_settings()))


@pytest.fixture()
def keyless_client():
    return TestClient(create_app(_settings(_private_key="")))


# ------------------------------------------------------------------ health


def test_health_reports_readiness_without_leaking_the_key(client):
    r = client.get("/health")
    assert r.status_code == 200
    body = r.json()
    assert body["status"] == "ok"
    assert body["signing_enabled"] is True
    assert PK not in r.text
    assert "private" not in " ".join(body.keys()).lower()


def test_health_flags_that_the_model_is_not_on_real_data(client):
    body = client.get("/health").json()
    assert body["trained_on_real_data"] is False
    assert "BOOTSTRAP" in body["data_label"]


def test_model_report_is_served_for_the_ui(client):
    body = client.get("/model-report").json()
    assert body["metrics"]["auc_test"] > 0.5
    assert body["data_source"]["is_real_data"] is False
    assert len(body["score_bands"]) == 6


# ------------------------------------------------------------------- score


def test_score_returns_a_signature_that_recovers_to_the_model_signer(client):
    body = client.post("/score", json={"address": WALLET}).json()
    assert body["signed"] is True
    assert body["signer"] == SIGNER

    att = body["attestation"]
    rebuilt = build(
        wallet=att["wallet"], score=att["score"], model_version=att["modelVersion"],
        feature_hash=att["featureHash"], ttl_seconds=0, now=att["expiry"], nonce=att["nonce"],
    )
    assert recover(rebuilt, body["chain_id"], ORACLE, body["signature"]) == SIGNER


def test_score_is_inside_the_contract_range(client):
    body = client.post("/score", json={"address": WALLET}).json()
    assert 300 <= body["score"] <= 900
    assert 11_000 <= body["collateral_ratio_bps"] <= 15_000


def test_score_returns_all_eight_features_with_a_source_each(client):
    body = client.post("/score", json={"address": WALLET}).json()
    assert len(body["features"]) == 8
    for f in body["features"]:
        assert f["source"] in {"synthetic", "chain"}
        assert "contribution" in f and "value" in f


def test_score_labels_synthetic_features(client):
    body = client.post("/score", json={"address": WALLET}).json()
    prov = body["feature_provenance"]
    assert prov["fully_real"] is False
    assert prov["warning"]
    assert len(prov["synthetic_features"]) == 8


def test_calldata_is_ready_to_broadcast(client):
    body = client.post("/score", json={"address": WALLET}).json()
    assert body["calldata"].startswith("0xf5dbf8f7")
    assert body["to"] == ORACLE


def test_nonce_survives_a_javascript_json_parse(client):
    """A browser parses JSON numbers as doubles, which would round a 96-bit
    nonce and break the digest. The API sends it as a decimal string."""
    body = client.post("/score", json={"address": WALLET}).json()
    nonce = body["attestation"]["nonce"]
    assert isinstance(nonce, str)
    assert str(int(nonce)) == nonce
    assert int(nonce) > 2**53, "test is meaningless if the nonce fits in a double"


def test_two_scores_use_different_nonces(client):
    a = client.post("/score", json={"address": WALLET}).json()
    b = client.post("/score", json={"address": WALLET}).json()
    assert a["attestation"]["nonce"] != b["attestation"]["nonce"]
    assert a["score"] == b["score"], "the same wallet must score identically"


def test_expiry_respects_the_configured_ttl(client):
    body = client.post("/score", json={"address": WALLET}).json()
    att = body["attestation"]
    assert 0 < att["expiry"] - body["issued_at"] <= 7 * 24 * 3600


def test_different_wallets_score_differently(client):
    a = client.post("/score", json={"address": WALLET}).json()
    b = client.post("/score", json={"address": OTHER}).json()
    assert a["feature_hash"] != b["feature_hash"]


def test_lowercase_address_is_accepted_and_checksummed(client):
    body = client.post("/score", json={"address": WALLET.lower()}).json()
    assert body["wallet"] == WALLET


@pytest.mark.parametrize("bad", ["", "0x123", "not-an-address", "0x" + "z" * 40])
def test_malformed_addresses_are_rejected(client, bad):
    assert client.post("/score", json={"address": bad}).status_code == 422


def test_scoring_without_a_key_fails_closed(keyless_client):
    r = keyless_client.post("/score", json={"address": WALLET})
    assert r.status_code == 503
    assert "MODEL_SIGNER_PRIVATE_KEY" in r.json()["detail"]


def test_health_still_works_without_a_key(keyless_client):
    body = keyless_client.get("/health").json()
    assert body["status"] == "ok"
    assert body["signing_enabled"] is False


# ------------------------------------------------------------- attestation


def test_attestation_is_404_before_the_wallet_is_scored(client):
    assert client.get(f"/attestation/{OTHER}").status_code == 404


def test_attestation_returns_what_was_issued(client):
    issued = client.post("/score", json={"address": WALLET}).json()
    fetched = client.get(f"/attestation/{WALLET}").json()
    assert fetched["signature"] == issued["signature"]
    assert fetched["attestation"] == issued["attestation"]


def test_attestation_lookup_is_case_insensitive(client):
    client.post("/score", json={"address": WALLET})
    assert client.get(f"/attestation/{WALLET.lower()}").status_code == 200


def test_attestation_rejects_a_malformed_address(client):
    assert client.get("/attestation/0x123").status_code == 422


# -------------------------------------------------------------- the key


def test_no_endpoint_ever_returns_the_private_key(client):
    client.post("/score", json={"address": WALLET})
    for path in ["/health", "/model-report", f"/attestation/{WALLET}"]:
        assert PK not in client.get(path).text
        assert PK.removeprefix("0x") not in client.get(path).text
    body = client.post("/score", json={"address": WALLET})
    assert PK not in body.text
    assert PK.removeprefix("0x") not in body.text
