"""Signing behaviour that ScoreOracle depends on."""

import json
from pathlib import Path

import pytest
from eth_account import Account

from signer.attestation import (
    HALF_CURVE_ORDER,
    build,
    calldata,
    digest,
    domain,
    recover,
    sign,
)
from signer.fixtures import create_address

# anvil development account #1: public, secures nothing.
PK = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"
ORACLE = "0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0"
WALLET = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
CHAIN = 31337
FIXTURE = Path("contracts/test/fixtures/python_attestation.json")


def _att(**kw):
    base = dict(
        wallet=WALLET, score=742, model_version=1,
        feature_hash="0x" + "ab" * 32, ttl_seconds=3600, now=1_787_000_000, nonce=1,
    )
    base.update(kw)
    return build(**base)


def test_signature_recovers_to_the_signing_key():
    att = _att()
    out = sign(att, CHAIN, ORACLE, PK)
    assert out["signer"] == Account.from_key(PK).address
    assert recover(att, CHAIN, ORACLE, out["signature"]) == out["signer"]


def test_signature_is_low_s():
    # High-s signatures are rejected on chain with MalleableSignature().
    for nonce in range(25):
        out = sign(_att(nonce=nonce), CHAIN, ORACLE, PK)
        assert int(out["s"], 16) <= HALF_CURVE_ORDER
        assert out["v"] in (27, 28)


def test_digest_is_independent_of_the_key():
    att = _att()
    assert digest(att, CHAIN, ORACLE) == sign(att, CHAIN, ORACLE, PK)["digest"]


def test_domain_binds_chain_and_contract():
    att = _att()
    base = digest(att, CHAIN, ORACLE)
    assert digest(att, 1, ORACLE) != base, "chain id must change the digest"
    assert digest(att, CHAIN, "0x" + "11" * 20) != base, "contract must change the digest"


def test_every_field_is_bound_by_the_signature():
    att = _att()
    base = digest(att, CHAIN, ORACLE)
    assert digest(_att(score=743), CHAIN, ORACLE) != base
    assert digest(_att(model_version=2), CHAIN, ORACLE) != base
    assert digest(_att(feature_hash="0x" + "cd" * 32), CHAIN, ORACLE) != base
    assert digest(_att(nonce=2), CHAIN, ORACLE) != base
    assert digest(_att(ttl_seconds=7200), CHAIN, ORACLE) != base
    assert digest(_att(wallet="0x" + "22" * 20), CHAIN, ORACLE) != base


def test_expiry_is_issue_time_plus_ttl():
    att = _att(now=1_000_000, ttl_seconds=900)
    assert att.expiry == 1_000_900


def test_random_nonces_do_not_repeat():
    nonces = {build(WALLET, 700, 1, "0x" + "00" * 32, 3600).nonce for _ in range(500)}
    assert len(nonces) == 500


def test_calldata_uses_the_contract_selector():
    att = _att()
    out = sign(att, CHAIN, ORACLE, PK)
    # cast sig "submitAttestation((address,uint16,uint32,bytes32,uint64,uint256),bytes)"
    assert calldata(att, out["signature"]).startswith("0xf5dbf8f7")


def test_domain_is_the_one_the_contract_builds():
    d = domain(CHAIN, ORACLE)
    assert d["name"] == "Karma" and d["version"] == "1"
    assert d["chainId"] == CHAIN


def test_create_address_derivation_matches_the_committed_fixture():
    fixture = json.loads(FIXTURE.read_text())
    assert create_address(fixture["deployer"], 0) == fixture["scoreOracle"]


def test_committed_fixture_still_verifies():
    """The same fixture CrossLanguageSignature.t.sol checks, verified from Python."""
    f = json.loads(FIXTURE.read_text())
    att = build(
        wallet=f["wallet"], score=f["score"], model_version=f["modelVersion"],
        feature_hash=f["featureHash"], ttl_seconds=0, now=f["expiry"], nonce=f["nonce"],
    )
    assert digest(att, f["chainId"], f["scoreOracle"]) == f["digest"]
    assert recover(att, f["chainId"], f["scoreOracle"], f["signature"]) == f["signer"]


def test_nonce_zero_deployer_only():
    with pytest.raises(ValueError):
        create_address("0x" + "11" * 20, 1)
