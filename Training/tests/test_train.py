import json
from pathlib import Path

import torch
from PIL import Image

from model import net, prep, train


def _write_page(root: Path, render_id: str, source_id: str, page_index: int,
                 width_px: int = 60, height_px: int = 60,
                 staff_space_px: float = 12.0) -> None:
    """One prep page small enough to fit in a single tile, carrying one
    `noteheadBlack` glyph so the tile has a real (nonzero) target."""
    d = root / render_id
    d.mkdir(parents=True, exist_ok=True)
    png_name = f"page_{page_index}.prep.png"
    (d / f"page_{page_index}.prep.json").write_text(json.dumps({
        "schema": 1, "render_id": render_id, "source_id": source_id,
        "face": "ms4/Bravura", "page_index": page_index,
        "image": {"file": png_name, "width_px": width_px,
                  "height_px": height_px, "staff_space_px": staff_space_px,
                  "scale": 0.5, "source_width_px": width_px * 2,
                  "source_height_px": height_px * 2, "source_dpi": 300.0,
                  "deskew_degrees": 0.0},
        "glyphs": [{"class": "noteheadBlack", "center_px": [30.0, 30.0],
                    "origin_px": [24.0, 30.0], "advance_px": 12.0,
                    "rendered_size_px": 9.0}],
    }))
    Image.new("L", (width_px, height_px), color=200).save(d / png_name)


def test_training_runs_two_steps_on_cpu(tmp_path):
    # Not a quality check — a wiring check. seed=0 puts "src_0"/"src_1"
    # in the train split and "src_10" in val (brute-forced against
    # prep.split_of the same way test_prep.py's
    # test_the_split_covers_all_three_buckets does), so this three-page
    # root exercises both loaders for real, including the validation
    # pass. Each page is smaller than --tile, so it yields exactly one
    # crop (dataset.tile_origins), which makes the train split exactly 2
    # tiles: batch=1 x epochs=1 is therefore exactly two optimizer steps.
    prep_root = tmp_path / "prep"
    _write_page(prep_root, "r_train_0", "src_0", 0)
    _write_page(prep_root, "r_train_1", "src_1", 0)
    _write_page(prep_root, "r_val_0", "src_10", 0)

    assert prep.split_of("src_0", 0, seed=0) == "train"
    assert prep.split_of("src_1", 0, seed=0) == "train"
    assert prep.split_of("src_10", 0, seed=0) == "val"

    out = tmp_path / "out"
    exit_code = train.main([
        "--prep-root", str(prep_root), "--out", str(out),
        "--epochs", "1", "--batch", "1", "--lr", "1e-3",
        "--tile", "128", "--overlap", "32", "--seed", "0",
        "--device", "cpu",
    ])
    assert exit_code == 0

    checkpoint_path = out / "checkpoint.pt"
    assert checkpoint_path.exists()
    checkpoint = torch.load(checkpoint_path, map_location="cpu",
                             weights_only=False)
    assert set(checkpoint) == {"model_state_dict", "epoch", "val_loss",
                                "hyperparams"}
    # the val split is nonempty (src_10), so the checkpoint was saved via
    # the best-validation-loss path, not the empty-val fallback.
    assert checkpoint["val_loss"] is not None
    assert checkpoint["hyperparams"]["epochs"] == 1
    assert checkpoint["hyperparams"]["batch"] == 1

    # At least one TRAINABLE parameter must actually differ from
    # initialization — this is what would catch a loop that "runs" (right
    # exit code, right files) but never calls optimizer.step(), e.g. a
    # stray torch.no_grad() around the training pass. Reconstructing a
    # same-seeded model reproduces the exact pre-training init: main()
    # seeds torch before building anything, and nothing between that
    # seed call and model construction draws from the global RNG (the
    # sampler uses its own, separately-seeded Generator).
    #
    # Deliberately checked via named_parameters(), NOT state_dict(): a
    # BatchNorm layer's running_mean/running_var are BUFFERS that update
    # on every forward pass regardless of optimizer.step() — an earlier
    # version of this assertion used state_dict() and kept passing after
    # optimizer.step() was commented out, because those buffers alone
    # made the two state dicts differ. Restricting to parameters is what
    # actually pins the optimizer step.
    torch.manual_seed(0)
    fresh_params = dict(net.SymbolNet(num_classes=len(prep.VOCABULARY)).named_parameters())
    trained_params = checkpoint["model_state_dict"]
    changed = any(
        not torch.equal(fresh_params[name], trained_params[name])
        for name in fresh_params
    )
    assert changed

    log_text = (out / "train.log").read_text()
    assert '"epochs": 1' in log_text
    assert '"torch"' in log_text  # resolved package versions were logged
    assert "epoch=0" in log_text  # the loop actually ran an epoch
    assert "done best_val_loss=" in log_text
