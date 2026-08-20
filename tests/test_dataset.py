import json
from pathlib import Path

import pandas as pd
import pytest

from model.dataset import ProvenanceError, declare, load
from model.features import FEATURE_NAMES


def _write_csv(path: Path, rows: int = 40) -> Path:
    frame = pd.DataFrame(
        {name: [float(i % 7) + 1 for i in range(rows)] for name in FEATURE_NAMES}
    )
    frame["defaulted"] = [i % 2 for i in range(rows)]
    frame.to_csv(path, index=False)
    return path


def test_undeclared_dataset_is_refused(tmp_path):
    csv = _write_csv(tmp_path / "bootstrap_mystery.csv")
    with pytest.raises(ProvenanceError, match="no provenance sidecar"):
        load(csv)


def test_synthetic_data_must_say_so_in_its_filename(tmp_path):
    csv = _write_csv(tmp_path / "totally_real_wallets.csv")
    declare(csv, kind="bootstrap", query_url=None, note=None)
    with pytest.raises(ProvenanceError, match="filename does not say so"):
        load(csv)


def test_declared_bootstrap_loads_and_is_flagged_not_real(tmp_path):
    csv = _write_csv(tmp_path / "bootstrap_ok.csv")
    declare(csv, kind="bootstrap", query_url=None, note=None)
    frame, prov = load(csv)
    assert len(frame) == 40
    assert prov["is_real_data"] is False
    assert "BOOTSTRAP" in prov["label"]


def test_real_data_declaration_is_flagged_real(tmp_path):
    csv = _write_csv(tmp_path / "aave_v3_export.csv")
    declare(csv, kind="dune", query_url="https://dune.com/queries/1", note=None)
    _, prov = load(csv)
    assert prov["is_real_data"] is True
    assert prov["kind"] == "dune"


def test_a_kind_cannot_claim_real_without_being_a_real_kind(tmp_path):
    csv = _write_csv(tmp_path / "bootstrap_liar.csv")
    side = csv.with_suffix(csv.suffix + ".provenance.json")
    side.write_text(json.dumps({"kind": "vibes", "is_real_data": True}))
    with pytest.raises(ProvenanceError, match="claims real data"):
        load(csv)


def test_shipped_bootstrap_dataset_is_declared_synthetic():
    frame, prov = load(Path("model/data/bootstrap_wallets_v1.csv"))
    assert prov["is_real_data"] is False
    assert "bootstrap" in prov["file"]
    assert len(frame) > 0
