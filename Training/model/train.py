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
import platform
import random
from pathlib import Path

import numpy as np
import torch
from torch.utils.data import DataLoader, WeightedRandomSampler

from . import dataset, losses, net, prep

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
    parser.add_argument("--prep-root", required=True, type=Path)
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


def _make_loader(ds: dataset.SymbolTiles, batch_size: int,
                  sampler: WeightedRandomSampler | None) -> DataLoader:
    if sampler is not None:
        return DataLoader(ds, batch_size=batch_size, sampler=sampler)
    return DataLoader(ds, batch_size=batch_size, shuffle=False)


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

    hyperparams = {
        "prep_root": str(args.prep_root), "out": str(args.out),
        "epochs": args.epochs, "batch": args.batch, "lr": args.lr,
        "weight_decay": _WEIGHT_DECAY, "tile": args.tile,
        "overlap": args.overlap, "seed": args.seed, "device": str(device),
        "limit": args.limit,
    }
    log_lines = [
        f"hyperparams {json.dumps(hyperparams, sort_keys=True)}",
        f"versions {json.dumps(_package_versions(), sort_keys=True)}",
    ]

    index = prep.PrepIndex(args.prep_root)
    if args.limit is not None:
        index.pages = index.pages[:args.limit]

    train_ds = dataset.SymbolTiles(index, "train", tile=args.tile,
                                    overlap=args.overlap, seed=args.seed)
    val_ds = dataset.SymbolTiles(index, "val", tile=args.tile,
                                  overlap=args.overlap, seed=args.seed)

    sampler_generator = torch.Generator().manual_seed(args.seed)
    train_sampler = (
        WeightedRandomSampler(train_ds.weights, num_samples=len(train_ds),
                               replacement=True, generator=sampler_generator)
        if len(train_ds) > 0 else None
    )
    train_loader = _make_loader(train_ds, args.batch, train_sampler)
    val_loader = _make_loader(val_ds, args.batch, None)

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
        train_loss = _run_epoch(model, train_loader, optimizer, device,
                                 train=True)
        val_loss = (_run_epoch(model, val_loader, optimizer, device,
                                train=False)
                    if len(val_loader) > 0 else None)
        scheduler.step()

        val_text = "nan" if val_loss is None else f"{val_loss:.6f}"
        log_lines.append(
            f"epoch={epoch} train_loss={train_loss:.6f} "
            f"val_loss={val_text} lr={scheduler.get_last_lr()[0]:.6g}")

        if val_loss is not None and val_loss < best_val:
            best_val = val_loss
            _save_checkpoint(checkpoint_path, model, epoch, val_loss,
                              hyperparams)
            saved = True

    # `checkpoint.pt` must exist regardless of whether any epoch ever
    # validated (an empty val split is a degenerate but legal input) —
    # fall back to the final epoch's weights.
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
