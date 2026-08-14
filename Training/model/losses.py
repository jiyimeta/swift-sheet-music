"""Losses for training `net.SymbolNet`: the CenterNet penalty-reduced
focal loss for the heatmap head, and a masked L1 for the offset/geom
regression heads (only the cells `dataset.SymbolTiles` placed a target
on — its `mask` channel — carry gradient)."""

from __future__ import annotations

import torch


def focal(logits: torch.Tensor, target: torch.Tensor) -> torch.Tensor:
    """CenterNet's penalty-reduced focal loss (Law & Deng, CornerNet;
    adopted by Zhou et al., CenterNet/Objects as Points). `target` is the
    Gaussian-splatted heatmap from `dataset.SymbolTiles`: exactly 1 at a
    glyph centre, smoothly falling toward (but never reaching) 0 around
    it. Only cells at exactly 1 are "positive"; every other cell is
    penalized as negative, down-weighted by `(1 - target) ** 4` so a
    false positive next to a real peak costs far less than one far from
    any peak — the class imbalance this exists for is extreme (§ dataset
    docstring: `noteheadBlack` 55,675 times vs. the rarest class 16, in a
    600-page sample)."""
    pred = torch.sigmoid(logits).clamp(1e-4, 1 - 1e-4)
    pos = target.eq(1).float()
    neg = 1 - pos
    pos_loss = -((1 - pred) ** 2) * torch.log(pred) * pos
    neg_loss = -((1 - target) ** 4) * (pred ** 2) * torch.log(1 - pred) * neg
    n = pos.sum().clamp(min=1)
    return (pos_loss.sum() + neg_loss.sum()) / n


def masked_l1(pred: torch.Tensor, target: torch.Tensor, mask: torch.Tensor) -> torch.Tensor:
    """Mean absolute error over only the elements `mask` marks positive.
    `mask` carries a single channel (matching `dataset.SymbolTiles`'s
    offset/geom mask) and is broadcast across `pred`/`target`'s channel
    dimension before both the multiply and the normalizing count, so the
    result is a true per-element mean over the masked (cell, channel)
    pairs — comparable whether `pred` has 2 channels (offset) or 4
    (geom)."""
    mask = mask.expand_as(pred)
    diff = (pred - target).abs() * mask
    n = mask.sum().clamp(min=1)
    return diff.sum() / n
