"""Command line entry point.

    python -m signer.cli serve                       # run the API
    python -m signer.cli score 0xabc... --dry-run    # score without signing
    python -m signer.cli keygen                      # make a dev signer key

--dry-run never reads MODEL_SIGNER_PRIVATE_KEY, so it is safe to run in any
environment, including one where the key is deliberately absent.
"""

from __future__ import annotations

import argparse
import json
import sys

from .config import ConfigError, Settings
from .service import ScoringService


def _print_human(payload: dict) -> None:
    src = payload.get("data_source", {})
    prov = payload.get("feature_provenance", {})

    print()
    if not src.get("is_real_data", False):
        print(f"  !! {src.get('label', 'model trained on synthetic data')}")
    if prov.get("synthetic_features"):
        print(f"  !! synthetic features: {', '.join(prov['synthetic_features'])}")
    print()
    print(f"  wallet            {payload['wallet']}")
    print(f"  score             {payload['score']}")
    print(f"  P(default)        {payload['probability_of_default']}")
    print(f"  collateral ratio  {payload['collateral_ratio_percent']}%")
    print(f"  model version     {payload['model_version']}")
    print()
    print("  feature                      value        source      contribution")
    for f in payload["features"]:
        print(
            f"  {f['name']:<27} {f['value']:>12}  {f['source']:<10} {f['contribution']:>+8.0f}"
        )
    print()
    print(f"  featureHash       {payload['feature_hash']}")
    if "digest" in payload:
        print(f"  digest            {payload['digest']}")
    if payload.get("signed"):
        print(f"  signer            {payload['signer']}")
        print(f"  signature         {payload['signature']}")
        print(f"  to                {payload['to']}")
        print(f"  calldata          {payload['calldata'][:66]}...")
    else:
        note = payload.get("dry_run_note") or payload.get("warning") or "not signed"
        print(f"  NOT SIGNED        {note}")
    print()


def cmd_score(args) -> int:
    settings = Settings.from_env()
    if args.oracle:
        settings.score_oracle_address = args.oracle
    if args.chain_id:
        settings.chain_id = args.chain_id

    service = ScoringService.build(settings)
    try:
        payload = service.score_wallet(args.address, sign=not args.dry_run)
    except ConfigError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    print(json.dumps(payload, indent=2)) if args.json else _print_human(payload)
    return 0


def cmd_serve(args) -> int:
    import uvicorn

    from .app import create_app

    settings = Settings.from_env()
    if args.oracle:
        settings.score_oracle_address = args.oracle
    if args.chain_id:
        settings.chain_id = args.chain_id

    if not settings.can_sign:
        print(
            "warning: MODEL_SIGNER_PRIVATE_KEY is unset. /score will return 503 until "
            "it is set; /health and /model-report still work.",
            file=sys.stderr,
        )
    uvicorn.run(create_app(settings), host=args.host, port=args.port, log_level=args.log_level)
    return 0


def cmd_keygen(args) -> int:
    """Generate a throwaway signer key for local development."""
    from eth_account import Account

    acct = Account.create()
    print("Development signer key. Testnet only - do not reuse anywhere real.\n")
    print(f"MODEL_SIGNER_PRIVATE_KEY={acct.key.hex()}")
    print(f"MODEL_SIGNER_ADDRESS={acct.address}")
    print("\nAdd both to .env (which is gitignored), then redeploy so ScoreOracle")
    print("registers this address as a model signer.")
    return 0


def cmd_health(args) -> int:
    service = ScoringService.build(Settings.from_env())
    print(json.dumps(service.health(), indent=2))
    return 0


def main(argv: list | None = None) -> int:
    parser = argparse.ArgumentParser(prog="signer", description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("score", help="score one wallet")
    s.add_argument("address")
    s.add_argument("--dry-run", action="store_true", help="score and hash, never sign")
    s.add_argument("--json", action="store_true", help="machine-readable output")
    s.add_argument("--oracle", default=None, help="override the ScoreOracle address")
    s.add_argument("--chain-id", type=int, default=None)
    s.set_defaults(func=cmd_score)

    v = sub.add_parser("serve", help="run the HTTP API")
    v.add_argument("--host", default="127.0.0.1")
    v.add_argument("--port", type=int, default=8000)
    v.add_argument("--log-level", default="info")
    v.add_argument("--oracle", default=None)
    v.add_argument("--chain-id", type=int, default=None)
    v.set_defaults(func=cmd_serve)

    k = sub.add_parser("keygen", help="generate a development signer key")
    k.set_defaults(func=cmd_keygen)

    h = sub.add_parser("health", help="print service status")
    h.set_defaults(func=cmd_health)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
