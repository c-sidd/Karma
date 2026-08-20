"""The eight features Karma scores a wallet on, and their canonical encoding.

Every feature here is derivable from public chain history. Nothing is
self-reported, nothing comes from off-chain identity, and nothing requires the
borrower's cooperation to compute.

The canonical encoding matters as much as the features. `feature_hash` produces
the bytes32 that goes into the signed attestation, committing the signer to the
exact inputs that produced the score. The chain does not recompute it - it
cannot, the data is not on chain in that form - but anyone holding the feature
vector can verify that the signer scored what they claim to have scored.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Mapping, Sequence

from eth_abi import encode as abi_encode
from eth_utils import keccak, to_checksum_address


@dataclass(frozen=True)
class Feature:
    name: str
    description: str
    #: Multiplier applied before integer quantisation for the canonical hash.
    scale: int
    #: Sign of a healthy value. +1 means "more is better credit".
    direction: int
    unit: str

    def quantise(self, value: float) -> int:
        if value < 0:
            raise ValueError(f"{self.name} must be non-negative, got {value}")
        return int(round(value * self.scale))


FEATURES: tuple[Feature, ...] = (
    Feature(
        "wallet_age_days",
        "Days since the wallet's first on-chain transaction.",
        scale=1,
        direction=+1,
        unit="days",
    ),
    Feature(
        "tx_count_90d",
        "Transactions in the last 90 days. Distinguishes a live wallet from a dormant one.",
        scale=1,
        direction=+1,
        unit="count",
    ),
    Feature(
        "total_borrow_usd",
        "Lifetime borrow volume across lending markets, in USD.",
        scale=100,
        direction=+1,
        unit="USD",
    ),
    Feature(
        "repay_to_borrow_ratio",
        "Lifetime repaid divided by lifetime borrowed. The core repayment signal.",
        scale=1_000_000,
        direction=+1,
        unit="ratio",
    ),
    Feature(
        "liquidation_count",
        "Times this wallet has been liquidated. The strongest negative signal.",
        scale=1,
        direction=-1,
        unit="count",
    ),
    Feature(
        "max_leverage_ratio",
        "Peak debt-to-collateral ever held. How close to the edge this wallet operates.",
        scale=1_000_000,
        direction=-1,
        unit="ratio",
    ),
    Feature(
        "distinct_assets_borrowed",
        "Distinct assets borrowed. Breadth of protocol experience.",
        scale=1,
        direction=+1,
        unit="count",
    ),
    Feature(
        "avg_position_duration_days",
        "Mean days a borrow position stayed open. Separates lenders from flash traders.",
        scale=1_000,
        direction=+1,
        unit="days",
    ),
)

FEATURE_NAMES: tuple[str, ...] = tuple(f.name for f in FEATURES)

assert len(FEATURES) == 8, "the attestation and the UI both assume exactly eight features"


def schema_hash() -> bytes:
    """Identifies the feature set itself.

    Changing a name, an order or a scale changes this hash, so a feature vector
    produced under one schema can never be read as though it were another.
    """
    spec = ";".join(f"{f.name}:{f.scale}" for f in FEATURES)
    return keccak(text=f"KarmaFeatureVector(v1){{{spec}}}")


def feature_vector(row: Mapping[str, float]) -> list[float]:
    """Pull the eight features out of a mapping, in canonical order."""
    missing = [n for n in FEATURE_NAMES if n not in row]
    if missing:
        raise KeyError(f"missing features: {missing}")
    return [float(row[n]) for n in FEATURE_NAMES]


def quantise(values: Sequence[float]) -> list[int]:
    if len(values) != len(FEATURES):
        raise ValueError(f"expected {len(FEATURES)} features, got {len(values)}")
    return [f.quantise(v) for f, v in zip(FEATURES, values)]


def feature_hash(wallet: str, model_version: int, values: Sequence[float]) -> bytes:
    """The bytes32 committed to inside a signed attestation.

    keccak256(abi.encode(schemaHash, wallet, modelVersion, uint256[8] quantised))
    """
    encoded = abi_encode(
        ["bytes32", "address", "uint32", "uint256[8]"],
        [schema_hash(), to_checksum_address(wallet), int(model_version), quantise(values)],
    )
    return keccak(encoded)


def describe() -> list[dict]:
    """Feature metadata for the report and the UI."""
    return [
        {
            "name": f.name,
            "description": f.description,
            "unit": f.unit,
            "direction": f.direction,
            "scale": f.scale,
        }
        for f in FEATURES
    ]
