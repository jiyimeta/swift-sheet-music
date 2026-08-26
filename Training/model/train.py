"""Trains `net.SymbolNet` on a `prep.PrepIndex`: AdamW + a per-epoch
cosine schedule, fp32 throughout (no AMP — this slice is
correctness-first; mixed precision on MPS is a variable nobody wants in
the first end-to-end number), on CPU or Apple's MPS backend. `main` is
also the CLI entry point (`python -m model.train ...` or
`Training/.venv/bin/python Training/model/train.py ...`).

Writes two files under `--out`: `checkpoint.pt` (the best-validation-loss
epoch's `model_state_dict`, plus the hyperparameters and the epoch/loss it
was saved at) and `train.log` (every hyperparameter, the resolved package
versions, and one line per epoch) — so a later run that sweeps the open
parameters can attribute its results table to an exact, reproducible
configuration.
"""

from __future__ import annotations

import argparse
import importlib.metadata as metadata
import json
import os
import platform
import random
import time
from pathlib import Path

import numpy as np
import torch
from torch.utils.data import DataLoader, WeightedRandomSampler

from . import augment, dataset, losses, net, prep

#: Fixed per the brief; not exposed as a CLI flag.
_WEIGHT_DECAY = 1e-4

#: Versions worth recording for run attribution — the same set pinned in
#: Training/requirements.txt. Queried via package metadata rather than
#: imported, so this module only imports what it actually uses.
_TRACKED_PACKAGES = (
    "torch", "numpy", "pillow", "coremltools", "onnx", "scipy", "pypdfium2",
)


def _parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Train SymbolNet on a prep root.")
    parser.add_argument("--prep-root", required=True, type=Path, nargs="+",
                         help="One or more prep roots, concatenated. Passing "
                              "the clean and the degraded export together is "
                              "how the model is trained on both; the split is "
                              "keyed on (source_id, page_index), so a page "
                              "held out of one root is held out of all of "
                              "them.")
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--epochs", type=int, default=10)
    parser.add_argument("--batch", type=int, default=16)
    parser.add_argument("--lr", type=float, default=1e-3)
    parser.add_argument("--tile", type=int, default=384)
    parser.add_argument("--overlap", type=int, default=64)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--device", type=str, default=None,
                         help="Force a device (e.g. 'cpu'); default: mps "
                              "if available, else cpu.")
    parser.add_argument("--limit", type=int, default=None,
                         help="Cap the number of pages loaded from "
                              "--prep-root, before splitting — for fast "
                              "local iteration over a large real root.")
    parser.add_argument("--samples-per-epoch", type=int, default=None,
                         help="Tiles drawn per epoch. Default: the train "
                              "split's size. Pin it when comparing runs "
                              "whose train splits differ in size — adding "
                              "a second --prep-root doubles the split, and "
                              "an unpinned epoch would then also double "
                              "the optimizer steps, confounding the data "
                              "change with a schedule change.")
    parser.add_argument("--augment", type=str, default="none",
                         choices=["none", "photometric"],
                         help="Training-tile augmentation (train split "
                              "only). Default 'none' so a run is "
                              "comparable with the pre-augmentation "
                              "checkpoints; 'photometric' applies "
                              "model.augment.PhotometricAugment. The "
                              "default is expected to change once the two "
                              "have been measured against each other on "
                              "the held-out split.")
    parser.add_argument("--workers", type=int, default=None,
                         help="DataLoader worker processes. Default: "
                              "cpu_count - 2, capped at 8. 0 loads in the "
                              "training process. Measured: the loader "
                              "spends ~80%% of a tile's wall clock in "
                              "PIL decode (17.9 ms of 22.4 ms), and every "
                              "one of a page's ~30 tiles re-decodes the "
                              "whole page PNG, so this is the flag that "
                              "moves epoch time. Does NOT change results: "
                              "DataLoader yields batches in sampler order "
                              "whatever the worker count "
                              "(test_loader_batches_are_worker_count_"
                              "invariant pins that).")
    return parser.parse_args(argv)


def _resolve_device(requested: str | None) -> torch.device:
    if requested:
        return torch.device(requested)
    if torch.backends.mps.is_available():
        return torch.device("mps")
    return torch.device("cpu")


def _seed_everything(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)


def _package_versions() -> dict[str, str]:
    versions = {"python": platform.python_version()}
    for name in _TRACKED_PACKAGES:
        try:
            versions[name] = metadata.version(name)
        except metadata.PackageNotFoundError:
            versions[name] = "not-installed"
    return versions


def _resolve_workers(requested: int | None) -> int:
    """`--workers` if given, else `cpu_count - 2` capped at 8 — two cores
    left for the training process itself and the OS, and a cap because
    the loader saturates well before every core is a worker."""
    if requested is not None:
        if requested < 0:
            raise ValueError(f"--workers must be >= 0, got {requested}")
        return requested
    return max(0, min(8, (os.cpu_count() or 1) - 2))


def _make_loader(ds: dataset.SymbolTiles, batch_size: int,
                  sampler: WeightedRandomSampler | None,
                  workers: int = 0) -> DataLoader:
    """The loader for one split.

    `num_workers > 0` is the whole reason this function has a knob: a
    tile costs 22.4 ms in-process and 17.9 ms of that is PIL decoding the
    ENTIRE page PNG, which every one of a page's ~30 tiles does again
    from scratch. Measured on this dataset at batch 16: 359 ms/batch at
    0 workers, 125 at 4, 65 at 8 — a 5.5x on the loader.

    macOS starts workers by SPAWN, not fork, so each one re-imports torch
    and unpickles the dataset (~107 MB over the full 4650-page prep root).
    `persistent_workers` keeps that a once-per-run cost rather than a
    once-per-epoch one; without it an 8-epoch run pays it 16 times. It
    also means the caller MUST be under `if __name__ == "__main__"` —
    `main` is, via this module's own entry point.
    """
    extra: dict = {}
    if workers > 0:
        extra = {"num_workers": workers, "persistent_workers": True,
                 "prefetch_factor": 4}
    if sampler is not None:
        return DataLoader(ds, batch_size=batch_size, sampler=sampler, **extra)
    return DataLoader(ds, batch_size=batch_size, shuffle=False, **extra)


def _run_epoch(model: net.SymbolNet, loader: DataLoader,
                optimizer: torch.optim.Optimizer, device: torch.device,
                train: bool) -> float:
    """One pass over `loader`: forward, the three losses summed, and
    (only when `train`) backward + optimizer step. Returns the mean loss
    over batches (0.0 if `loader` yields none)."""
    model.train(train)
    total_loss = 0.0
    batches = 0
    context = torch.enable_grad() if train else torch.no_grad()
    with context:
        for image, hm, off, geom, mask in loader:
            image = image.to(device)
            hm = hm.to(device)
            off = off.to(device)
            geom = geom.to(device)
            mask = mask.to(device)

            hm_logits, offset_pred, geom_pred = model(image)
            loss = (losses.focal(hm_logits, hm)
                    + losses.masked_l1(offset_pred, off, mask)
                    + losses.masked_l1(geom_pred, geom, mask))

            if train:
                optimizer.zero_grad()
                loss.backward()
                optimizer.step()

            total_loss += float(loss.detach())
            batches += 1
    return total_loss / max(1, batches)


def _save_checkpoint(path: Path, model: net.SymbolNet, epoch: int,
                      val_loss: float | None, hyperparams: dict) -> None:
    torch.save({
        "model_state_dict": model.state_dict(),
        "epoch": epoch,
        "val_loss": val_loss,
        "hyperparams": hyperparams,
    }, path)


def main(argv: list[str] | None = None) -> int:
    args = _parse_args(argv)
    _seed_everything(args.seed)
    device = _resolve_device(args.device)
    args.out.mkdir(parents=True, exist_ok=True)

    workers = _resolve_workers(args.workers)
    hyperparams = {
        "prep_root": [str(r) for r in args.prep_root], "out": str(args.out),
        "epochs": args.epochs, "batch": args.batch, "lr": args.lr,
        "weight_decay": _WEIGHT_DECAY, "tile": args.tile,
        "overlap": args.overlap, "seed": args.seed, "device": str(device),
        "limit": args.limit, "workers": workers, "augment": args.augment,
    }
    log_lines = [
        f"hyperparams {json.dumps(hyperparams, sort_keys=True)}",
        f"versions {json.dumps(_package_versions(), sort_keys=True)}",
    ]

    index = prep.PrepIndex(args.prep_root)
    if args.limit is not None:
        index.pages = index.pages[:args.limit]

    train_ds = dataset.SymbolTiles(index, "train", tile=args.tile,
                                    overlap=args.overlap, seed=args.seed,
                                    augment=augment.from_name(args.augment))
    val_ds = dataset.SymbolTiles(index, "val", tile=args.tile,
                                  overlap=args.overlap, seed=args.seed)
    # An empty val split used to be tolerated: every epoch logged
    # `val_loss=nan`, no epoch ever beat `best_val = inf`, and the run
    # still wrote a checkpoint — the LAST epoch's weights, not the best
    # ones, with `val_loss: None` inside it. Nothing said so. The P3d
    # round hit it through a small `--limit` (the split is a hash of
    # (source_id, page_index), so a short enough page prefix can land
    # entirely in train) and the only symptom was a model that had
    # trained past its own best epoch. Refuse instead: there is no
    # legitimate run of this trainer with nothing to validate against.
    if len(val_ds) == 0:
        raise ValueError(
            f"the val split of {[str(r) for r in args.prep_root]} is empty "
            f"({len(index.pages)} pages loaded"
            + (f", capped by --limit {args.limit}" if args.limit is not None else "")
            + f", {len(train_ds)} train tiles) — every epoch would report "
            "val_loss=nan and the checkpoint would silently be the last "
            "epoch's weights rather than the best. Raise --limit or point "
            "--prep-root at a root with more sources.")

    # How many tiles one epoch draws. Defaults to the train split's size,
    # which is what "an epoch" normally means — but the sampler draws WITH
    # REPLACEMENT, so the number is already a schedule knob rather than a
    # pass over the data.
    #
    # It has to be settable because the comparison this round runs needs
    # it. Adding the degraded prep root to `--prep-root` doubles the train
    # split, and leaving this at `len(train_ds)` would double the
    # optimizer steps per epoch as well — so a clean-only run and a
    # clean+degraded run would differ in TWO ways at once, and no result
    # could be attributed to the data. Pinning it makes the pool the only
    # difference.
    samples_per_epoch = args.samples_per_epoch or len(train_ds)
    hyperparams["samples_per_epoch"] = samples_per_epoch
    sampler_generator = torch.Generator().manual_seed(args.seed)
    train_sampler = (
        WeightedRandomSampler(train_ds.weights, num_samples=samples_per_epoch,
                               replacement=True, generator=sampler_generator)
        if len(train_ds) > 0 else None
    )
    train_loader = _make_loader(train_ds, args.batch, train_sampler, workers)
    val_loader = _make_loader(val_ds, args.batch, None, workers)

    model = net.SymbolNet(num_classes=len(prep.VOCABULARY)).to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr,
                                   weight_decay=_WEIGHT_DECAY)
    scheduler = torch.optim.lr_scheduler.CosineAnnealingLR(
        optimizer, T_max=max(1, args.epochs))

    checkpoint_path = args.out / "checkpoint.pt"
    best_val = float("inf")
    saved = False
    last_epoch = -1
    for epoch in range(args.epochs):
        last_epoch = epoch
        epoch_started = time.monotonic()
        train_loss = _run_epoch(model, train_loader, optimizer, device,
                                 train=True)
        val_loss = (_run_epoch(model, val_loader, optimizer, device,
                                train=False)
                    if len(val_loader) > 0 else None)
        scheduler.step()

        val_text = "nan" if val_loss is None else f"{val_loss:.6f}"
        line = (f"epoch={epoch} train_loss={train_loss:.6f} "
                f"val_loss={val_text} lr={scheduler.get_last_lr()[0]:.6g} "
                f"epoch_seconds={time.monotonic() - epoch_started:.1f}")
        log_lines.append(line)
        # Flushed after EVERY epoch, and echoed to stdout, rather than
        # written once at the end: a multi-hour run that is killed
        # otherwise leaves a `checkpoint.pt` with no record of what
        # produced it, and there is no way to watch an epoch's wall clock
        # while it is still deciding whether the schedule fits.
        print(line, flush=True)
        (args.out / "train.log").write_text("\n".join(log_lines) + "\n")

        # The LAST epoch's weights, every epoch, next to the best-val
        # one. Two reasons, and the second is the important one:
        #
        # - A run long enough to be killed (an epoch is MPS-bound at
        #   ~20 min on this host, so an 8-epoch run is hours) otherwise
        #   leaves only whatever epoch last improved val loss, which can
        #   be epoch 0.
        # - **Selecting on val loss is itself under suspicion here.** The
        #   previous round's val loss rose monotonically from epoch 1
        #   while held-out seam recall matched train recall exactly (see
        #   "Held out at scale"), so the quantity the checkpoint is chosen
        #   by is not the quantity the model is judged on. Keeping the
        #   last epoch makes that comparable instead of unrecoverable.
        _save_checkpoint(args.out / "checkpoint_last.pt", model, epoch,
                          val_loss, hyperparams)

        if val_loss is not None and val_loss < best_val:
            best_val = val_loss
            _save_checkpoint(checkpoint_path, model, epoch, val_loss,
                              hyperparams)
            saved = True

    # An empty val split is refused above, so the remaining way to reach
    # this is a val loss that is NaN in every epoch (NaN < inf is False,
    # so nothing is ever "best"). Keep the fallback so a run still leaves
    # weights behind, but it now means "training diverged", not "there was
    # nothing to validate against".
    if not saved:
        _save_checkpoint(checkpoint_path, model, last_epoch, None,
                          hyperparams)

    best_text = "nan" if best_val == float("inf") else f"{best_val:.6f}"
    log_lines.append(f"done best_val_loss={best_text} "
                      f"checkpoint={checkpoint_path}")
    (args.out / "train.log").write_text("\n".join(log_lines) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
