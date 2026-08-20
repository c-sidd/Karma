"""Loading a training set, and refusing to guess where it came from.

Every dataset must carry a provenance sidecar next to it:

    model/data/foo.csv
    model/data/foo.csv.provenance.json

The bootstrap generator writes one automatically. For a Dune export you declare
it once:

    python -m model.dataset declare model/data/aave_v3_ethereum_2025.csv \
        --kind dune --query-url https://dune.com/queries/...

A dataset with no sidecar does not load. That is deliberate: the one failure
mode worth engineering against here is a synthetic number being presented as a
real one, and a missing sidecar is exactly the state in which that mistake
happens.
"""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path

import pandas as pd

from .features import FEATURE_NAMES

LABEL_COLUMN = "defaulted"
REAL_KINDS = {"dune", "onchain"}


class ProvenanceError(RuntimeError):
    pass


def sidecar_path(data_path: Path) -> Path:
    return data_path.with_suffix(data_path.suffix + ".provenance.json")


def read_provenance(data_path: Path) -> dict:
    side = sidecar_path(data_path)
    if not side.exists():
        raise ProvenanceError(
            f"no provenance sidecar for {data_path}.\n"
            f"Expected {side}.\n"
            "Generate bootstrap data with `python -m model.bootstrap_data`, or declare a "
            "real export with `python -m model.dataset declare <csv> --kind dune "
            "--query-url <url>`."
        )
    prov = json.loads(side.read_text())
    if "is_real_data" not in prov or "kind" not in prov:
        raise ProvenanceError(f"{side} must set both 'kind' and 'is_real_data'")
    if prov["is_real_data"] and prov["kind"] not in REAL_KINDS:
        raise ProvenanceError(
            f"{side} claims real data with kind={prov['kind']!r}; expected one of {sorted(REAL_KINDS)}"
        )
    if not prov["is_real_data"] and "bootstrap" not in data_path.name:
        raise ProvenanceError(
            f"{data_path} is synthetic but its filename does not say so. "
            "Rename it to contain 'bootstrap'."
        )
    return prov


def load(data_path: str | Path) -> tuple[pd.DataFrame, dict]:
    """Return (frame, provenance). Raises unless the dataset declares itself."""
    path = Path(data_path)
    if not path.exists():
        raise FileNotFoundError(
            f"{path} not found. Generate the fallback with:\n"
            "    python -m model.bootstrap_data"
        )
    prov = read_provenance(path)
    frame = pd.read_csv(path)

    missing = [c for c in (*FEATURE_NAMES, LABEL_COLUMN) if c not in frame.columns]
    if missing:
        raise ValueError(f"{path} is missing required columns: {missing}")
    if frame[LABEL_COLUMN].nunique() < 2:
        raise ValueError(f"{path} has only one class in '{LABEL_COLUMN}'")

    frame = frame.dropna(subset=list(FEATURE_NAMES) + [LABEL_COLUMN])
    prov = dict(prov)
    prov["file"] = str(path)
    prov["n_rows_loaded"] = int(len(frame))
    return frame, prov


def declare(data_path: Path, kind: str, query_url: str | None, note: str | None) -> Path:
    """Write a provenance sidecar for a dataset you exported yourself."""
    is_real = kind in REAL_KINDS
    frame = pd.read_csv(data_path)
    prov = {
        "kind": kind,
        "is_real_data": is_real,
        "label": (
            f"REAL DATA - {kind}" if is_real else "BOOTSTRAP - SYNTHETIC DATA, NOT REAL ON-CHAIN ACTIVITY"
        ),
        "query_url": query_url,
        "note": note,
        "n_rows": int(len(frame)),
        "default_rate": float(frame[LABEL_COLUMN].mean()) if LABEL_COLUMN in frame else None,
        "declared_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }
    side = sidecar_path(data_path)
    side.write_text(json.dumps(prov, indent=2) + "\n")
    return side


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest="cmd", required=True)

    d = sub.add_parser("declare", help="write a provenance sidecar for a dataset")
    d.add_argument("path", type=Path)
    d.add_argument("--kind", required=True, choices=sorted(REAL_KINDS | {"bootstrap"}))
    d.add_argument("--query-url", default=None)
    d.add_argument("--note", default=None)

    i = sub.add_parser("inspect", help="show a dataset's provenance and shape")
    i.add_argument("path", type=Path)

    args = p.parse_args(argv)

    if args.cmd == "declare":
        side = declare(args.path, args.kind, args.query_url, args.note)
        print(f"wrote {side}")
        return 0

    frame, prov = load(args.path)
    print(json.dumps(prov, indent=2))
    print(f"\nrows={len(frame)}  default_rate={frame[LABEL_COLUMN].mean():.4f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
