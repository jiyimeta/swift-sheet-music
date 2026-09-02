import json
from pathlib import Path

import pytest
import torch
from PIL import Image
from torch.utils.data import WeightedRandomSampler

from model import dataset, net, prep, train


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
        "--device", "cpu", "--workers", "0",
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


def test_empty_val_split_is_refused(tmp_path):
    # Every source here hashes into "train" at seed 0, so the val split
    # is empty. The old behavior was silent: `val_loss=nan` in every
    # epoch line, `best_val` never beaten, and a checkpoint written from
    # the LAST epoch's weights carrying `val_loss: None`. Nothing in the
    # exit code or the file set distinguished it from a healthy run, and
    # the P3d round reached it through a small --limit.
    prep_root = tmp_path / "prep"
    _write_page(prep_root, "r_train_0", "src_0", 0)
    _write_page(prep_root, "r_train_1", "src_1", 0)
    assert prep.split_of("src_0", 0, seed=0) == "train"
    assert prep.split_of("src_1", 0, seed=0) == "train"

    out = tmp_path / "out"
    with pytest.raises(ValueError) as excinfo:
        train.main([
            "--prep-root", str(prep_root), "--out", str(out),
            "--epochs", "1", "--batch", "1", "--tile", "128",
            "--overlap", "32", "--seed", "0", "--device", "cpu",
            "--workers", "0",
        ])
    # The message has to name the knob that causes this in practice and
    # say what the silent outcome would have been — a bare "empty val
    # split" leaves the reader to rediscover both.
    message = str(excinfo.value)
    assert "val split" in message
    assert "--limit" in message
    assert "last" in message

    # And nothing was written: refusing after writing a checkpoint would
    # leave exactly the artifact the refusal exists to prevent.
    assert not (out / "checkpoint.pt").exists()


def test_empty_val_split_message_reports_the_limit_that_caused_it(tmp_path):
    # Same refusal, reached the way the round actually reached it — a
    # --limit short enough to cut the only val-split page off. The
    # message must quote the limit, since that is the thing to change.
    prep_root = tmp_path / "prep"
    _write_page(prep_root, "r_train_0", "src_0", 0)
    _write_page(prep_root, "r_train_1", "src_1", 0)
    _write_page(prep_root, "r_val_0", "src_10", 0)
    assert prep.split_of("src_10", 0, seed=0) == "val"

    # Unlimited, the same root trains fine — so the refusal below is
    # attributable to --limit and nothing else about the fixture.
    assert train.main([
        "--prep-root", str(prep_root), "--out", str(tmp_path / "ok"),
        "--epochs", "1", "--batch", "1", "--tile", "128", "--overlap", "32",
        "--seed", "0", "--device", "cpu", "--workers", "0",
    ]) == 0

    with pytest.raises(ValueError, match=r"--limit 2"):
        train.main([
            "--prep-root", str(prep_root), "--out", str(tmp_path / "out"),
            "--epochs", "1", "--batch", "1", "--tile", "128",
            "--overlap", "32", "--seed", "0", "--device", "cpu",
            "--workers", "0", "--limit", "2",
        ])


def test_resolve_workers_defaults_below_the_core_count_and_caps(monkeypatch):
    # The default has to leave cores for the training process itself, and
    # cap: the loader saturates long before every core is a worker.
    monkeypatch.setattr(train.os, "cpu_count", lambda: 10)
    assert train._resolve_workers(None) == 8
    monkeypatch.setattr(train.os, "cpu_count", lambda: 4)
    assert train._resolve_workers(None) == 2
    monkeypatch.setattr(train.os, "cpu_count", lambda: 64)
    assert train._resolve_workers(None) == 8
    # A single-core host must resolve to 0, not a negative worker count.
    monkeypatch.setattr(train.os, "cpu_count", lambda: 1)
    assert train._resolve_workers(None) == 0
    # An explicit value always wins, including 0.
    monkeypatch.setattr(train.os, "cpu_count", lambda: 10)
    assert train._resolve_workers(0) == 0
    assert train._resolve_workers(3) == 3
    with pytest.raises(ValueError):
        train._resolve_workers(-1)


def test_loader_batches_are_worker_count_invariant(tmp_path):
    # --workers is a speed knob and must not be a results knob. A
    # DataLoader hands batches back in sampler order however many worker
    # processes produce them, so the same seed must give byte-identical
    # batches at 0 and at 2 workers. Without this, a run's numbers would
    # silently depend on the host's core count.
    prep_root = tmp_path / "prep"
    for i in range(6):
        _write_page(prep_root, f"r_{i}", f"src_{i}", 0)
    index = prep.PrepIndex(prep_root)
    ds = dataset.SymbolTiles(index, "train", tile=128, overlap=32, seed=0)
    assert len(ds) >= 4

    def batches(workers: int):
        generator = torch.Generator().manual_seed(0)
        sampler = WeightedRandomSampler(ds.weights, num_samples=len(ds),
                                        replacement=True,
                                        generator=generator)
        loader = train._make_loader(ds, 2, sampler, workers)
        # Anti-vacuity: an equality that compares two SERIAL loaders is
        # not testing anything. Pin that the parallel arm really is
        # parallel before comparing its output.
        assert loader.num_workers == workers
        return [tuple(t.clone() for t in batch) for batch in loader]

    serial = batches(0)
    parallel = batches(2)
    assert len(serial) == len(parallel)
    for a, b in zip(serial, parallel):
        for ta, tb in zip(a, b):
            assert torch.equal(ta, tb)


def test_two_prep_roots_train_together(tmp_path):
    # The clean+degraded run this exists for. Both roots hold the SAME
    # sources, so the split is unchanged and the only difference is that
    # each page is now seen twice, once per root — which is what makes
    # the train tile count double while the val split stays populated.
    clean = tmp_path / "clean"
    degraded = tmp_path / "degraded"
    for root, suffix in ((clean, ""), (degraded, "_frozen")):
        _write_page(root, f"r_train_0{suffix}", "src_0", 0)
        _write_page(root, f"r_train_1{suffix}", "src_1", 0)
        _write_page(root, f"r_val_0{suffix}", "src_10", 0)

    one = prep.PrepIndex(clean)
    two = prep.PrepIndex([clean, degraded])
    assert len(two.pages) == 2 * len(one.pages)

    out = tmp_path / "out"
    assert train.main([
        "--prep-root", str(clean), str(degraded), "--out", str(out),
        "--epochs", "1", "--batch", "1", "--tile", "128", "--overlap", "32",
        "--seed", "0", "--device", "cpu", "--workers", "0",
    ]) == 0

    log = (out / "train.log").read_text()
    # Both roots are recorded, so a saved log says which data produced it
    # — a single-root string would make two very different runs
    # indistinguishable after the fact.
    assert str(clean) in log and str(degraded) in log
    checkpoint = torch.load(out / "checkpoint.pt", map_location="cpu",
                             weights_only=False)
    assert checkpoint["val_loss"] is not None
    assert len(checkpoint["hyperparams"]["prep_root"]) == 2


def test_every_epoch_leaves_a_last_checkpoint_and_a_flushed_log(tmp_path):
    # An epoch is MPS-bound at ~20 minutes on the development host, so a
    # full schedule runs for hours and WILL be interrupted. Both of these
    # used to be written only at the very end, or only when val loss
    # improved: a killed run left a checkpoint from whichever epoch last
    # improved (often epoch 0) and no log at all.
    #
    # `checkpoint_last.pt` also exists because selecting on val loss is
    # itself under suspicion — the previous round's val loss rose from
    # epoch 1 while held-out recall did not fall.
    prep_root = tmp_path / "prep"
    _write_page(prep_root, "r_train_0", "src_0", 0)
    _write_page(prep_root, "r_train_1", "src_1", 0)
    _write_page(prep_root, "r_val_0", "src_10", 0)

    out = tmp_path / "out"
    assert train.main([
        "--prep-root", str(prep_root), "--out", str(out),
        "--epochs", "3", "--batch", "1", "--tile", "128", "--overlap", "32",
        "--seed", "0", "--device", "cpu", "--workers", "0",
    ]) == 0

    last = torch.load(out / "checkpoint_last.pt", map_location="cpu",
                       weights_only=False)
    assert last["epoch"] == 2, "checkpoint_last.pt must hold the FINAL epoch"

    log = (out / "train.log").read_text()
    for epoch in range(3):
        assert f"epoch={epoch} " in log
    # The per-epoch wall clock is in the line, so a schedule can be sized
    # from a partial run instead of guessed.
    assert "epoch_seconds=" in log


def test_samples_per_epoch_pins_the_step_count_across_differing_split_sizes(tmp_path):
    # The control this round's A/B comparison depends on. Two roots hold
    # the same sources, so adding the second doubles the train split; with
    # an unpinned epoch the B run would take twice A's optimizer steps and
    # the two would differ in data AND schedule at once.
    clean = tmp_path / "clean"
    degraded = tmp_path / "degraded"
    for root, suffix in ((clean, ""), (degraded, "_frozen")):
        _write_page(root, f"r_train_0{suffix}", "src_0", 0)
        _write_page(root, f"r_train_1{suffix}", "src_1", 0)
        _write_page(root, f"r_val_0{suffix}", "src_10", 0)

    one_root_train = len(dataset.SymbolTiles(
        prep.PrepIndex(clean), "train", tile=128, overlap=32, seed=0))
    two_root_train = len(dataset.SymbolTiles(
        prep.PrepIndex([clean, degraded]), "train", tile=128, overlap=32, seed=0))
    assert two_root_train == 2 * one_root_train, "the fixture must actually double"

    def steps(prep_roots, extra):
        out = tmp_path / f"out{len(extra)}{len(prep_roots)}"
        assert train.main([
            "--prep-root", *[str(r) for r in prep_roots], "--out", str(out),
            "--epochs", "1", "--batch", "1", "--tile", "128", "--overlap", "32",
            "--seed", "0", "--device", "cpu", "--workers", "0", *extra,
        ]) == 0
        return torch.load(out / "checkpoint_last.pt", map_location="cpu",
                           weights_only=False)["hyperparams"]["samples_per_epoch"]

    # Unpinned, the epoch grows with the split — the confound.
    assert steps([clean], []) == one_root_train
    assert steps([clean, degraded], []) == two_root_train
    # Pinned, it does not.
    pinned = ["--samples-per-epoch", str(one_root_train)]
    assert steps([clean, degraded], pinned) == one_root_train
