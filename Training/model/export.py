"""Packages a trained (or freshly initialized) `net.SymbolNet` checkpoint
into the three artifacts the Swift side consumes:

- `model.mlpackage` — Apple inference. `OMRDetectorFrontEnd` runs tiles
  through this.
- `model.onnx` — the canonical artifact by design decision. Nothing in
  Swift uses it this round; it exists so the later Android phase is a
  conversion of this graph rather than a retraining.
- `model.json` — the manifest. `OMRDetectorFrontEnd` reads it and asserts
  the class list against the frozen `prep.VOCABULARY` table, throwing if
  they disagree, before it will run any tile through the model at all.
  Also records `training_config_hash` (a hash of the checkpoint's own
  hyperparams dict — distinct from `commit`, which pins the code, not the
  run) and `decode_defaults_measured` (`false` until plan Task 17's sweep
  sets the decode constants from real val performance).

The exported graph is `net.ExportWrapper(model)`: the heatmap head already
carries its sigmoid, offset/geom pass through untouched. Peak extraction,
`geom` reconstruction, tile merging and the map into page coordinates all
happen in Swift (`decode.py` is the reference for that arithmetic, not the
inference path) — so the graph itself stays trivially convertible and the
Android phase can reuse the same decode against `model.onnx` later.

`main` is also the CLI entry point:

    Training/.venv/bin/python -m model.export \\
        --checkpoint ~/omr-models/run1/checkpoint.pt --out ~/omr-models/run1 \\
        --tile 384 --staff-space-px 12.0 --overlap 64

`--checkpoint random` skips loading a checkpoint file entirely and exports
a freshly initialized, untrained network — the floor a later gate (P3d-G1)
measures a trained model against, so it must be produced before any
training run, never after one that happened to look good.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import warnings
from pathlib import Path

import coremltools as ct
import onnx
import torch

from . import net, prep

#: Decode-time constants recorded in `model.json`. Per spec §11 these are
#: OPEN PARAMETERS a later sweep (plan Task 17, "sweep the open
#: parameters") chooses from val performance (detection threshold tau,
#: top-K, NMS radius) — this task only needs the manifest schema to be
#: complete before a trained model exists to sweep against. Because the
#: manifest shape gives them no visual distinction from a genuinely
#: measured field, `model.json` also carries `decode_defaults_measured:
#: false` alongside them (see `_write_manifest`) — Task 17 is the one
#: that flips it to `true`, once these three numbers stop being guesses.
_DEFAULT_THRESHOLD = 0.3
_DEFAULT_TOP_K = 300
_DEFAULT_NMS_RADIUS_SP = 0.5

#: `dataset._load_tile_image` normalizes pixels to [0, 1] by dividing by
#: 255 and applies no further per-channel standardization, so the network
#: this task exports was trained on raw [0, 1] input — mean 0 / std 1,
#: i.e. the identity transform. Recorded (not applied by anything this
#: round) so a future standardization change has a manifest field to land
#: in instead of a silent prep-root/model mismatch.
_INPUT_MEAN = 0.0
_INPUT_STD = 1.0

#: `net.SymbolNet`'s stem is two stride-2 conv/BN/ReLU blocks: fixed by the
#: architecture, not a hyperparameter, so it is not a CLI flag.
_STRIDE = 4


def _parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Export a SymbolNet checkpoint to Core ML, ONNX and a manifest.")
    parser.add_argument(
        "--checkpoint", required=True, type=str,
        help="Path to a checkpoint.pt written by model.train, or the "
             "literal 'random' for a freshly initialized, untrained "
             "network (the P3d-G1 floor).")
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--tile", type=int, default=384)
    parser.add_argument("--staff-space-px", type=float, default=12.0)
    parser.add_argument("--overlap", type=int, default=64)
    return parser.parse_args(argv)


def _repo_commit() -> str:
    """The commit `HEAD` resolves to in the worktree this module lives in,
    so a manifest can always be traced back to the code that produced its
    model. Best-effort: a checkout with no `.git` (e.g. a tarball) records
    "unknown" rather than failing the whole export over provenance."""
    try:
        result = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=Path(__file__).resolve().parent,
            capture_output=True, text=True, check=True)
        return result.stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def _training_config_hash(hyperparams: dict) -> str | None:
    """Distinct from `commit` (which pins the CODE): this pins the
    TRAINING RUN. Two checkpoints trained with different `lr` / `epochs`
    / `tile` / `overlap` but the same `prep_root` and `seed` would
    otherwise be indistinguishable in the manifest, and `prep_root` +
    `seed` alone is exactly the pair a mismatch like that could slip
    past. `None` for `--checkpoint random`, where `hyperparams` is `{}`
    and there is no training run to hash — a hash of `{}` would look like
    a real, reproducible answer instead of "there was nothing to hash."
    """
    if not hyperparams:
        return None
    return hashlib.sha256(
        json.dumps(hyperparams, sort_keys=True).encode()).hexdigest()


def _build_model(checkpoint_arg: str) -> tuple[net.SymbolNet, dict]:
    """Returns `(model, hyperparams)`. `hyperparams` is the training run's
    own recorded dict (`prep_root` / `seed` / ...) straight out of the
    checkpoint, or `{}` for `--checkpoint random` — there is no run to
    attribute.

    Architecture (`width`, `num_classes`) is read back from the
    checkpoint's own tensor shapes rather than a CLI flag or a hard-coded
    default, so a checkpoint trained at any width round-trips through
    export without export.py needing to know it in advance — including in
    tests, which use a narrow network purely for conversion speed.
    """
    if checkpoint_arg == "random":
        torch.manual_seed(0)
        return net.SymbolNet(num_classes=len(prep.VOCABULARY)), {}

    checkpoint = torch.load(checkpoint_arg, map_location="cpu", weights_only=False)
    state_dict = checkpoint["model_state_dict"]
    width = state_dict["stem.0.0.weight"].shape[0]
    num_classes = state_dict["heatmap_head.weight"].shape[0]
    model = net.SymbolNet(num_classes=num_classes, width=width)
    model.load_state_dict(state_dict)
    return model, checkpoint.get("hyperparams", {})


def _silence_known_export_deprecations() -> None:
    """Both export paths below go through `torch.jit.trace` (this module
    calls it directly for Core ML; `torch.onnx.export(..., dynamo=False)`
    calls it internally for ONNX) — a documented, still-functional API
    that torch 2.13 nudges callers away from in favor of `torch.compile` /
    `torch.export`. Switching was tried: `torch.export.export(...)` +
    `ct.convert` on the resulting `ExportedProgram` avoids this warning,
    but trades it for ~50 repeated internal
    `coremltools` `_TORCH_OPS_REGISTRY` deprecation warnings plus a
    `FutureWarning` from `torch.export`'s own pytree handling and a
    `ResourceWarning` from an implicitly-cleaned-up temp dir — strictly
    worse under the versions pinned in requirements.txt. `torch.jit.trace`
    is also what the plan's Step 3 specifies. Kept, with its own notice
    silenced deliberately rather than left to print on every export.
    Must be called inside a `warnings.catch_warnings()` block. One regex
    covers both `torch.jit.trace` and `torch.jit.trace_method`'s notices
    (the latter's message is a superstring of the former's)."""
    warnings.filterwarnings(
        "ignore", category=DeprecationWarning,
        message=r".*torch\.jit\.trace.* is deprecated\..*")


def _export_coreml(wrapped: torch.nn.Module, example: torch.Tensor,
                    tile: int, out: Path) -> None:
    with warnings.catch_warnings():
        _silence_known_export_deprecations()
        traced = torch.jit.trace(wrapped, example)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="image", shape=(1, 1, tile, tile))],
        outputs=[ct.TensorType(name="heatmap"), ct.TensorType(name="offset"),
                 ct.TensorType(name="geom")],
        compute_precision=ct.precision.FLOAT16,
        convert_to="mlprogram",
    )
    mlmodel.save(str(out / "model.mlpackage"))


def _export_onnx(wrapped: torch.nn.Module, example: torch.Tensor, out: Path) -> None:
    onnx_path = out / "model.onnx"
    # torch 2.13 defaults `dynamo=True`, which needs the `onnxscript`
    # package — not a pinned dependency here. `dynamo=False` (the legacy
    # TorchScript-based exporter, which traces internally) is a
    # deliberate choice, not a fallback, so its own deprecation notices
    # are expected; they are silenced by message rather than left to
    # print on every export.
    with warnings.catch_warnings():
        _silence_known_export_deprecations()
        warnings.filterwarnings(
            "ignore", category=DeprecationWarning,
            message=".*legacy TorchScript-based ONNX export.*")
        warnings.filterwarnings(
            "ignore", category=DeprecationWarning,
            message=".*feature will be removed.*")
        torch.onnx.export(
            wrapped, (example,), str(onnx_path),
            input_names=["image"], output_names=["heatmap", "offset", "geom"],
            opset_version=17, dynamo=False)
    onnx.checker.check_model(str(onnx_path))


def _write_manifest(out: Path, args: argparse.Namespace, hyperparams: dict,
                     checkpoint_arg: str) -> None:
    manifest = {
        "classes": list(prep.VOCABULARY),
        "staff_space_px": args.staff_space_px,
        "tile": args.tile,
        "overlap": args.overlap,
        "stride": _STRIDE,
        "mean": _INPUT_MEAN,
        "std": _INPUT_STD,
        "threshold": _DEFAULT_THRESHOLD,
        "top_k": _DEFAULT_TOP_K,
        "nms_radius_sp": _DEFAULT_NMS_RADIUS_SP,
        # False until plan Task 17's sweep sets these three from measured
        # val performance — see the constants' doc comment above. A
        # consumer (or a later gate) can refuse to trust threshold/top_k/
        # nms_radius_sp programmatically by reading this flag rather than
        # having to know out-of-band that they are still placeholders.
        "decode_defaults_measured": False,
        "commit": _repo_commit(),
        "training_config_hash": _training_config_hash(hyperparams),
        "prep_root": hyperparams.get("prep_root"),
        "seed": hyperparams.get("seed"),
        "checkpoint": checkpoint_arg,
    }
    (out / "model.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n")


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    args.out.mkdir(parents=True, exist_ok=True)

    model, hyperparams = _build_model(args.checkpoint)
    model.eval()
    wrapped = net.ExportWrapper(model)
    wrapped.eval()
    example = torch.zeros(1, 1, args.tile, args.tile)

    _export_coreml(wrapped, example, args.tile, args.out)
    _export_onnx(wrapped, example, args.out)
    _write_manifest(args.out, args, hyperparams, args.checkpoint)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
