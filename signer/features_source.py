"""Where a wallet's features come from.

Karma's honest answer is an indexer over Aave v3 events - the query is in
model/dune_queries.sql. That needs an account and a pipeline, so this module
defines the interface and ships two providers:

  DemoFeatureProvider      deterministic pseudo-features derived from the
                           address itself. Every value is synthetic and every
                           response says so, per feature.

  EtherscanFeatureProvider fills wallet_age_days and tx_count_90d from real
                           chain data via the free Etherscan API when a key is
                           present, and falls back to the demo provider for the
                           six features that need lending-protocol history.

Both tag each feature with its source, so a response can never present a
synthesised number as an observed one.
"""

from __future__ import annotations

import math
import time
from dataclasses import dataclass
from typing import Protocol

from eth_utils import keccak, to_checksum_address

from model.features import FEATURE_NAMES

SYNTHETIC = "synthetic"
CHAIN = "chain"

DEMO_WARNING = (
    "Feature values marked 'synthetic' are derived deterministically from the "
    "address and describe no real activity."
)


@dataclass(frozen=True)
class FeatureSet:
    values: dict
    sources: dict
    provider: str

    @property
    def is_fully_real(self) -> bool:
        return all(s == CHAIN for s in self.sources.values())

    def describe(self) -> dict:
        return {
            "provider": self.provider,
            "fully_real": self.is_fully_real,
            "real_features": sorted(n for n, s in self.sources.items() if s == CHAIN),
            "synthetic_features": sorted(n for n, s in self.sources.items() if s != CHAIN),
            "warning": None if self.is_fully_real else DEMO_WARNING,
        }


class FeatureProvider(Protocol):
    name: str

    def fetch(self, address: str) -> FeatureSet: ...


def _stream(address: str) -> list:
    """Deterministic uniforms in [0,1) derived from the address."""
    seed = keccak(hexstr=to_checksum_address(address))
    out = []
    for i in range(16):
        chunk = keccak(seed + i.to_bytes(4, "big"))
        out.append(int.from_bytes(chunk[:8], "big") / 2**64)
        out.append(int.from_bytes(chunk[8:16], "big") / 2**64)
    return out


def _normal(u1: float, u2: float) -> float:
    """Box-Muller, so the demo features have the same shape as the training data."""
    u1 = min(max(u1, 1e-12), 1 - 1e-12)
    return math.sqrt(-2.0 * math.log(u1)) * math.cos(2.0 * math.pi * u2)


class DemoFeatureProvider:
    """Synthetic but self-consistent: one latent variable drives all eight.

    Without a shared latent, a wallet could come out with five liquidations and
    a perfect repayment ratio, and the score would be nonsense to look at.
    """

    name = "demo"

    def fetch(self, address: str) -> FeatureSet:
        u = _stream(address)
        z = _normal(u[0], u[1])  # latent creditworthiness, same role as in training

        values = {
            "wallet_age_days": round(min(max(math.exp(5.2 + 0.35 * z + 0.5 * _normal(u[2], u[3]) * 0.4), 1), 3600)),
            "tx_count_90d": max(0, round(math.exp(1.9 + 0.45 * z) + 3 * _normal(u[4], u[5]))),
            "total_borrow_usd": round(min(max(math.exp(8.6 + 0.55 * z + 0.6 * _normal(u[6], u[7])), 50), 5_000_000), 2),
            "repay_to_borrow_ratio": round(min(max(0.72 + 0.16 * z + 0.09 * _normal(u[8], u[9]), 0.0), 1.2), 6),
            "liquidation_count": max(0, round(math.exp(-0.15 - 1.05 * z) + 0.4 * _normal(u[10], u[11]))),
            "max_leverage_ratio": round(min(max(0.58 - 0.12 * z + 0.08 * _normal(u[12], u[13]), 0.01), 0.98), 6),
            "distinct_assets_borrowed": max(0, round(math.exp(0.55 + 0.3 * z))),
            "avg_position_duration_days": round(min(max(math.exp(2.1 + 0.42 * z), 0.05), 900), 3),
        }
        return FeatureSet(
            values={k: values[k] for k in FEATURE_NAMES},
            sources={k: SYNTHETIC for k in FEATURE_NAMES},
            provider=self.name,
        )


class EtherscanFeatureProvider:
    """Real wallet age and recent activity; demo values for the rest.

    Etherscan's free tier covers the two features that only need transaction
    history. The other six need Aave position history, which the free API does
    not provide, so they stay synthetic and are labelled as such.
    """

    name = "etherscan+demo"
    BASE_URL = "https://api.etherscan.io/v2/api"

    def __init__(self, api_key: str, chain_id: int = 1, timeout: float = 6.0):
        self.api_key = api_key
        self.chain_id = chain_id
        self.timeout = timeout
        self._fallback = DemoFeatureProvider()

    def fetch(self, address: str) -> FeatureSet:
        base = self._fallback.fetch(address)
        try:
            age_days, tx_90d = self._chain_activity(address)
        except Exception:
            # A rate limit or a network blip must not take scoring down; it just
            # means this wallet is scored on demo values, and says so.
            return base

        values = dict(base.values)
        sources = dict(base.sources)
        values["wallet_age_days"] = age_days
        values["tx_count_90d"] = tx_90d
        sources["wallet_age_days"] = CHAIN
        sources["tx_count_90d"] = CHAIN
        return FeatureSet(values=values, sources=sources, provider=self.name)

    def _chain_activity(self, address: str) -> tuple:
        import httpx

        params = {
            "chainid": self.chain_id,
            "module": "account",
            "action": "txlist",
            "address": address,
            "startblock": 0,
            "endblock": 99999999,
            "page": 1,
            "offset": 10000,
            "sort": "asc",
            "apikey": self.api_key,
        }
        with httpx.Client(timeout=self.timeout) as client:
            payload = client.get(self.BASE_URL, params=params).json()
        if payload.get("status") != "1" or not isinstance(payload.get("result"), list):
            raise RuntimeError(payload.get("message", "etherscan returned no result"))

        txs = payload["result"]
        if not txs:
            return 0, 0
        now = int(time.time())
        first = int(txs[0]["timeStamp"])
        cutoff = now - 90 * 86_400
        return (now - first) // 86_400, sum(1 for t in txs if int(t["timeStamp"]) >= cutoff)


def build_provider(etherscan_api_key: str = "") -> FeatureProvider:
    return EtherscanFeatureProvider(etherscan_api_key) if etherscan_api_key else DemoFeatureProvider()
