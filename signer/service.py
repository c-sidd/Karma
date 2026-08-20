"""The scoring pipeline, independent of HTTP.

Kept separate from app.py so the CLI (including --dry-run) and the API run the
exact same code path. A dry run differs in one respect only: it never touches
the private key.
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass
from pathlib import Path

from eth_utils import to_checksum_address

from model.features import FEATURE_NAMES
from model.risk_curve import ratio_bps
from model.scoring import KarmaModel

from . import attestation as att_mod
from .config import Settings
from .features_source import build_provider
from .store import AttestationStore


@dataclass
class ScoringService:
    settings: Settings
    model: KarmaModel
    provider: object
    store: AttestationStore
    report: dict

    @classmethod
    def build(cls, settings: Settings) -> "ScoringService":
        if not settings.model_path.exists():
            raise FileNotFoundError(
                f"{settings.model_path} not found. Train the model first:\n"
                "    make model"
            )
        report = {}
        if settings.report_path.exists():
            report = json.loads(Path(settings.report_path).read_text())
        return cls(
            settings=settings,
            model=KarmaModel.load(settings.model_path),
            provider=build_provider(settings.etherscan_api_key),
            store=AttestationStore(),
            report=report,
        )

    # ------------------------------------------------------------------ core

    def score_wallet(self, address: str, sign: bool = True) -> dict:
        """Score, and unless this is a dry run, sign.

        Everything except `signature` and `calldata` is produced identically in
        both modes, so a dry run shows exactly what would have been signed.
        """
        wallet = to_checksum_address(address)
        features = self.provider.fetch(wallet)
        result = self.model.score(wallet, features.values)

        contributions = {b["name"]: b for b in result.breakdown}
        feature_rows = [
            {
                "name": name,
                "value": result.feature_values[name],
                "source": features.sources[name],
                "contribution": contributions[name]["contribution"],
                "baseline": contributions[name]["baseline"],
            }
            for name in FEATURE_NAMES
        ]

        payload = {
            "wallet": wallet,
            "score": result.score,
            "probability_of_default": round(result.probability_of_default, 6),
            "model_version": result.model_version,
            "collateral_ratio_bps": result.collateral_ratio_bps,
            "collateral_ratio_percent": round(result.collateral_ratio_bps / 100, 2),
            "features": feature_rows,
            "feature_hash": result.feature_hash,
            "feature_provenance": features.describe(),
            "data_source": self.report.get("data_source", {}),
            "chain_id": self.settings.chain_id,
            "score_oracle": self.settings.score_oracle_address,
            "issued_at": int(time.time()),
        }

        oracle = self.settings.score_oracle_address
        if oracle:
            att = att_mod.build(
                wallet=wallet,
                score=result.score,
                model_version=result.model_version,
                feature_hash=result.feature_hash,
                ttl_seconds=self.settings.attestation_ttl_seconds,
            )
            payload["attestation"] = att.as_dict()
            payload["domain"] = att_mod.domain(self.settings.chain_id, oracle)
            payload["digest"] = att_mod.digest(att, self.settings.chain_id, oracle)

            if sign:
                signed = att_mod.sign(
                    att, self.settings.chain_id, oracle, self.settings.private_key()
                )
                payload.update(
                    {
                        "signature": signed["signature"],
                        "signer": signed["signer"],
                        "domain_separator": signed["domain_separator"],
                        "struct_hash": signed["struct_hash"],
                        "calldata": att_mod.calldata(att, signed["signature"]),
                        "to": oracle,
                        "signed": True,
                    }
                )
                self.store.put(wallet, payload)
            else:
                payload["signed"] = False
                payload["dry_run_note"] = (
                    "Dry run: scored and hashed, but never signed. The private key "
                    "was not read."
                )
        else:
            payload["signed"] = False
            payload["warning"] = (
                "No ScoreOracle address configured, so no attestation was built. "
                "Deploy the contracts or set KARMA_SCORE_ORACLE."
            )

        return payload

    def stored(self, address: str) -> dict | None:
        return self.store.get(address)

    def health(self) -> dict:
        src = self.report.get("data_source", {})
        return {
            "status": "ok",
            "model_loaded": True,
            "model_version": self.model.model_version,
            "model_auc": self.report.get("metrics", {}).get("auc_test"),
            "trained_on_real_data": bool(src.get("is_real_data", False)),
            "data_label": src.get("label"),
            "feature_provider": getattr(self.provider, "name", "unknown"),
            "attestations_held": len(self.store),
            **self.settings.redacted(),
        }
