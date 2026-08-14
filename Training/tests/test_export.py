import json
import subprocess
from pathlib import Path

import coremltools as ct
import onnx
import torch

from model import export, net, prep


def _write_checkpoint(path: Path, num_classes: int, width: int,
                       prep_root: str = "/data/prep", seed: int = 42) -> None:
    """A checkpoint.pt in exactly `train._save_checkpoint`'s shape, at a
    tiny `width` so `export.main`'s Core ML / ONNX conversion runs in a
    fraction of a second in tests — `width` is a pure speed knob here
    (export.py reads architecture back from the checkpoint's own tensor
    shapes, never from a CLI flag), independent of `tile`, which a real
    export varies."""
    torch.manual_seed(0)
    model = net.SymbolNet(num_classes=num_classes, width=width)
    torch.save({
        "model_state_dict": model.state_dict(),
        "epoch": 3,
        "val_loss": 0.1234,
        "hyperparams": {"prep_root": prep_root, "seed": seed, "tile": 384,
                         "overlap": 64, "epochs": 4},
    }, path)


def test_model_json_records_everything_swift_needs(tmp_path):
    checkpoint = tmp_path / "checkpoint.pt"
    _write_checkpoint(checkpoint, num_classes=len(prep.VOCABULARY), width=4)
    out = tmp_path / "out"

    exit_code = export.main([
        "--checkpoint", str(checkpoint), "--out", str(out),
        "--tile", "384", "--staff-space-px", "12.0", "--overlap", "64",
    ])
    assert exit_code == 0

    meta = json.loads((out / "model.json").read_text())
    assert meta["classes"] == prep.VOCABULARY          # order is the class index
    assert meta["staff_space_px"] == 12.0
    assert meta["tile"] == 384 and meta["overlap"] == 64
    assert meta["stride"] == 4
    assert set(meta) >= {"classes", "staff_space_px", "tile", "overlap",
                          "stride", "mean", "std", "threshold", "top_k",
                          "nms_radius_sp", "commit", "prep_root", "seed"}

    # The VALUES behind those required keys, not just their presence: a
    # manifest carrying one training run's prep_root/seed while actually
    # describing another checkpoint's weights is exactly the silent
    # prep-root/model mismatch the brief's docstring warns about for
    # "classes" — this pins the same failure mode for provenance.
    assert meta["prep_root"] == "/data/prep"
    assert meta["seed"] == 42
    # commit must be real repository state, not a hard-coded placeholder:
    # this worktree's HEAD is a 40-hex-char sha (verified independently of
    # export.py, by asking git directly, not by re-deriving export.py's
    # own answer).
    want_commit = subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=Path(__file__).resolve().parent,
        capture_output=True, text=True, check=True).stdout.strip()
    assert meta["commit"] == want_commit
    assert len(meta["commit"]) == 40


def test_the_onnx_graph_loads_and_has_three_outputs(tmp_path):
    checkpoint = tmp_path / "checkpoint.pt"
    _write_checkpoint(checkpoint, num_classes=5, width=4)
    out = tmp_path / "out"
    export.main([
        "--checkpoint", str(checkpoint), "--out", str(out),
        "--tile", "64", "--staff-space-px", "12.0", "--overlap", "16",
    ])

    model = onnx.load(str(out / "model.onnx"))
    onnx.checker.check_model(model)
    assert len(model.graph.output) == 3


def test_the_coreml_package_exists_and_takes_a_single_tile(tmp_path):
    checkpoint = tmp_path / "checkpoint.pt"
    _write_checkpoint(checkpoint, num_classes=5, width=4)
    out = tmp_path / "out"
    export.main([
        "--checkpoint", str(checkpoint), "--out", str(out),
        "--tile", "64", "--staff-space-px", "12.0", "--overlap", "16",
    ])

    spec = ct.models.MLModel(str(out / "model.mlpackage")).get_spec()
    assert [i.name for i in spec.description.input] == ["image"]
    assert [o.name for o in spec.description.output] == [
        "heatmap", "offset", "geom"]
    # The Swift side indexes the outputs by these names; a rename here is
    # a silent load failure there, not a compile error.


def test_checkpoint_random_exports_an_untrained_network_with_no_checkpoint_file(tmp_path):
    # A later gate (P3d-G1) exports an UNTRAINED network to measure the
    # floor before any training run exists, so the floor is not chosen
    # after seeing a result it likes. "random" must work with no
    # checkpoint file anywhere on disk, at the real (default-width, full
    # vocabulary) architecture, and the manifest must say plainly that
    # this run has no training provenance to report rather than silently
    # carrying over the previous export's prep_root/seed.
    out = tmp_path / "out"
    exit_code = export.main([
        "--checkpoint", "random", "--out", str(out),
        "--tile", "64", "--staff-space-px", "12.0", "--overlap", "16",
    ])
    assert exit_code == 0
    assert (out / "model.mlpackage").exists()
    assert (out / "model.onnx").exists()

    meta = json.loads((out / "model.json").read_text())
    assert meta["checkpoint"] == "random"
    assert meta["prep_root"] is None
    assert meta["seed"] is None
    assert meta["classes"] == prep.VOCABULARY

    spec = ct.models.MLModel(str(out / "model.mlpackage")).get_spec()
    assert [o.name for o in spec.description.output] == [
        "heatmap", "offset", "geom"]


def test_a_checkpoint_trained_at_a_different_width_still_round_trips(tmp_path):
    # export.py must read (width, num_classes) back from the checkpoint's
    # own tensor shapes, not assume the training default (width=32). A
    # hard-coded width=32 makes model.load_state_dict raise a shape
    # mismatch the moment a checkpoint of any other width is exported;
    # this test uses width=6, distinct from every other test's width=4,
    # specifically so a hard-coded width cannot pass it by coincidence.
    checkpoint = tmp_path / "checkpoint.pt"
    _write_checkpoint(checkpoint, num_classes=7, width=6)
    out = tmp_path / "out"
    exit_code = export.main([
        "--checkpoint", str(checkpoint), "--out", str(out),
        "--tile", "64", "--staff-space-px", "12.0", "--overlap", "16",
    ])
    assert exit_code == 0
    assert (out / "model.mlpackage").exists()
