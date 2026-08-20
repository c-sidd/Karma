"""FastAPI surface: one endpoint to score, one to fetch what was issued."""

from __future__ import annotations

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field, field_validator

from .config import ConfigError, Settings
from .service import ScoringService

ADDRESS_PATTERN = r"^0x[0-9a-fA-F]{40}$"


class ScoreRequest(BaseModel):
    address: str = Field(..., description="Wallet to score", pattern=ADDRESS_PATTERN)

    @field_validator("address")
    @classmethod
    def _checksum(cls, v: str) -> str:
        from eth_utils import to_checksum_address

        return to_checksum_address(v)


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    service = ScoringService.build(settings)

    app = FastAPI(
        title="Karma signer",
        version="1.0.0",
        description=(
            "Scores a wallet with the Karma credit model and signs the result as an "
            "EIP-712 attestation that ScoreOracle will accept. The signing key is read "
            "from the environment and is never returned by any endpoint."
        ),
    )
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origins,
        allow_methods=["GET", "POST"],
        allow_headers=["*"],
    )
    app.state.service = service

    @app.get("/health", tags=["meta"])
    def health() -> dict:
        return service.health()

    @app.get("/model-report", tags=["meta"])
    def model_report() -> dict:
        """The full evaluation report, so the UI can show provenance and metrics."""
        if not service.report:
            raise HTTPException(status_code=503, detail="model report not available")
        return service.report

    @app.post("/score", tags=["scoring"])
    def score(request: ScoreRequest) -> dict:
        """Score a wallet and return a signed attestation plus its calldata."""
        try:
            return service.score_wallet(request.address, sign=True)
        except ConfigError as exc:
            raise HTTPException(status_code=503, detail=str(exc)) from exc

    @app.get("/attestation/{address}", tags=["scoring"])
    def attestation(address: str) -> dict:
        """The most recent attestation issued for a wallet, if this process issued one."""
        import re

        if not re.match(ADDRESS_PATTERN, address):
            raise HTTPException(status_code=422, detail="not an address")
        stored = service.stored(address)
        if stored is None:
            raise HTTPException(
                status_code=404,
                detail="no attestation issued for this wallet by this service",
            )
        return stored

    return app


app = None  # populated by uvicorn through the factory in cli.py
