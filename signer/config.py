"""Settings, all from the environment.

MODEL_SIGNER_PRIVATE_KEY is the only secret here. It is read once at startup,
held in memory, and never logged or serialised. --dry-run does not read it at
all, which is what makes it safe to run anywhere.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_TTL_SECONDS = 3600
#: ScoreOracle.MAX_ATTESTATION_TTL. Anything longer is refused on chain.
MAX_TTL_SECONDS = 7 * 24 * 3600


class ConfigError(RuntimeError):
    pass


@dataclass
class Settings:
    model_path: Path = Path("model/artifacts/karma_model.joblib")
    report_path: Path = Path("model/artifacts/model_report.json")
    chain_id: int = 31337
    score_oracle_address: str = ""
    attestation_ttl_seconds: int = DEFAULT_TTL_SECONDS
    etherscan_api_key: str = ""
    cors_origins: list = field(default_factory=lambda: ["http://localhost:3000"])

    #: Never populated from a file, never returned by the API.
    _private_key: str = ""

    @classmethod
    def from_env(cls) -> "Settings":
        deployments = _load_deployment()
        chain_id = int(os.environ.get("KARMA_CHAIN_ID", deployments.get("chainId", 31337)))
        oracle = os.environ.get(
            "KARMA_SCORE_ORACLE", deployments.get("ScoreOracle", "")
        )
        ttl = int(os.environ.get("KARMA_ATTESTATION_TTL", DEFAULT_TTL_SECONDS))
        if ttl <= 0 or ttl > MAX_TTL_SECONDS:
            raise ConfigError(
                f"KARMA_ATTESTATION_TTL must be in (0, {MAX_TTL_SECONDS}]; got {ttl}"
            )
        origins = os.environ.get("KARMA_CORS_ORIGINS", "http://localhost:3000")
        return cls(
            model_path=Path(os.environ.get("KARMA_MODEL_PATH", "model/artifacts/karma_model.joblib")),
            report_path=Path(
                os.environ.get("KARMA_MODEL_REPORT", "model/artifacts/model_report.json")
            ),
            chain_id=chain_id,
            score_oracle_address=oracle,
            attestation_ttl_seconds=ttl,
            etherscan_api_key=os.environ.get("ETHERSCAN_API_KEY", ""),
            cors_origins=[o.strip() for o in origins.split(",") if o.strip()],
            _private_key=os.environ.get("MODEL_SIGNER_PRIVATE_KEY", ""),
        )

    # ------------------------------------------------------------------ key

    @property
    def can_sign(self) -> bool:
        return bool(self._private_key)

    def private_key(self) -> str:
        if not self._private_key:
            raise ConfigError(
                "MODEL_SIGNER_PRIVATE_KEY is not set.\n"
                "Set it in your environment, or run with --dry-run to score without signing."
            )
        return self._private_key

    def require_oracle(self) -> str:
        if not self.score_oracle_address:
            raise ConfigError(
                "No ScoreOracle address. Deploy the contracts first, or set "
                "KARMA_SCORE_ORACLE explicitly."
            )
        return self.score_oracle_address

    def redacted(self) -> dict:
        """Everything about the configuration except the thing that must not leak."""
        return {
            "model_path": str(self.model_path),
            "chain_id": self.chain_id,
            "score_oracle_address": self.score_oracle_address,
            "attestation_ttl_seconds": self.attestation_ttl_seconds,
            "signing_enabled": self.can_sign,
            "etherscan_enabled": bool(self.etherscan_api_key),
        }


def _load_deployment() -> dict:
    """Read the address book the deploy script wrote, if there is one."""
    import json

    chain = os.environ.get("KARMA_CHAIN_ID")
    candidates = []
    if chain:
        candidates.append(Path(f"contracts/deployments/{chain}.json"))
    candidates += [
        Path("contracts/deployments/11155111.json"),
        Path("contracts/deployments/31337.json"),
    ]
    for path in candidates:
        if path.exists():
            try:
                return json.loads(path.read_text())
            except (ValueError, OSError):
                continue
    return {}
