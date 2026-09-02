"""Photometric augmentation for the detector's training tiles.

Why this module exists: `Training/model/` had **no augmentation of any
kind**, and `run1` was fitted on the clean prep root only. The two
symptoms line up with that exactly — overfitting from epoch 1 (train loss
falls 11x while val rises monotonically), and a degraded-set recall of
0.6676 against a clean 0.9657 on a corruption the model had never seen one
example of.

**Photometric only, deliberately.** Every op here is a per-pixel or
per-neighbourhood intensity change: it moves no glyph, so the heatmap /
offset / geom / mask targets `SymbolTiles.__getitem__` builds stay exactly
correct. A geometric augmentation (rotation, scale, shear) would have to
transform those four target planes as well, and a mismatch there does not
crash — it silently trains the geometry heads against the wrong answer,
which is the failure mode this program has already paid for twice. That is
a separate change with its own gate, not a parameter of this one.

**Broader than the eval corruption, on purpose.** The frozen eval set is
degraded by `generate/profiles/scanner.toml`. If training reproduced those
exact parameters, a degraded-set improvement would partly measure
"trained on the test transform". The ranges below are wider and are not
read from that profile.

Reproducibility: every op draws from a caller-supplied `random.Random`, so
a run is reproducible for a fixed (seed, worker count). It is NOT
reproducible across different `--workers` values, because which worker
draws which tile changes — that is the same caveat any stochastic
augmentation carries, and `--workers 0` removes it.
"""

from __future__ import annotations

import random
from dataclasses import dataclass

import numpy as np
from scipy.ndimage import gaussian_filter


@dataclass(frozen=True)
class PhotometricAugment:
    """Probabilities and ranges for the five ops, all independent.

    A probability of 0 disables its op, so a configuration of all zeros is
    the identity — which `test_a_zero_probability_config_is_the_identity`
    pins, since that is the property an `--augment none` run relies on.
    """

    #: gain/bias about mid-grey: `clip(gain * (x - 0.5) + 0.5 + bias)`
    contrast_p: float = 0.8
    contrast_gain: tuple[float, float] = (0.75, 1.30)
    contrast_bias: tuple[float, float] = (-0.12, 0.12)

    #: `x ** gamma` — ink thickening / thinning, the dominant difference
    #: between a clean render and a photocopy
    gamma_p: float = 0.6
    gamma: tuple[float, float] = (0.70, 1.50)

    #: gaussian blur in normalized pixels (S = 12 px per staff space, so
    #: 1.1 px is under a tenth of a staff space — enough to soften a stem
    #: edge, not enough to merge two ledger lines)
    blur_p: float = 0.5
    blur_sigma: tuple[float, float] = (0.0, 1.10)

    #: additive gaussian sensor noise
    noise_p: float = 0.6
    noise_sigma: tuple[float, float] = (0.0, 0.06)

    #: salt-and-pepper specks — scanner dust and toner dropout
    speckle_p: float = 0.35
    speckle_fraction: tuple[float, float] = (0.0, 0.004)

    def apply(self, image: np.ndarray, rng: random.Random) -> np.ndarray:
        """`image` is float32 in [0, 1]; the result is too, same shape.

        Ops compose in a fixed order — tone, then optics, then sensor —
        because that is the order a real scan applies them, and because a
        fixed order keeps the composition reproducible from the RNG
        stream alone.
        """
        out = image
        copied = False

        if self.contrast_p > 0 and rng.random() < self.contrast_p:
            gain = rng.uniform(*self.contrast_gain)
            bias = rng.uniform(*self.contrast_bias)
            out = gain * (out - 0.5) + 0.5 + bias
            copied = True

        if self.gamma_p > 0 and rng.random() < self.gamma_p:
            gamma = rng.uniform(*self.gamma)
            # `**` on a negative value is nan, and the contrast step above
            # can push a pixel below zero, so clip before the power.
            out = np.clip(out, 0.0, 1.0) ** gamma
            copied = True

        if self.blur_p > 0 and rng.random() < self.blur_p:
            sigma = rng.uniform(*self.blur_sigma)
            if sigma > 0:
                out = gaussian_filter(out.astype(np.float32), sigma=sigma)
                copied = True

        if self.noise_p > 0 and rng.random() < self.noise_p:
            sigma = rng.uniform(*self.noise_sigma)
            if sigma > 0:
                # Drawn from a numpy Generator seeded off the SAME stream,
                # so the whole augmentation is a function of `rng` alone.
                noise_rng = np.random.default_rng(rng.getrandbits(63))
                out = out + noise_rng.normal(0.0, sigma, size=out.shape)
                copied = True

        if self.speckle_p > 0 and rng.random() < self.speckle_p:
            fraction = rng.uniform(*self.speckle_fraction)
            count = int(round(fraction * out.size))
            if count > 0:
                speck_rng = np.random.default_rng(rng.getrandbits(63))
                flat = np.clip(out, 0.0, 1.0).astype(np.float32).reshape(-1).copy()
                idx = speck_rng.integers(0, flat.size, size=count)
                flat[idx] = (speck_rng.random(count) < 0.5).astype(np.float32)
                out = flat.reshape(out.shape)
                copied = True

        if not copied:
            # Nothing fired. Return the input untouched rather than a
            # clipped copy: an "identity" that still allocates and clips
            # would hide a config that never augments anything.
            return image
        return np.clip(out, 0.0, 1.0).astype(np.float32)


#: Every probability zeroed — the identity, used by `--augment none`.
NONE = PhotometricAugment(
    contrast_p=0.0, gamma_p=0.0, blur_p=0.0, noise_p=0.0, speckle_p=0.0,
)


def from_name(name: str) -> PhotometricAugment | None:
    """`--augment` values. `none` returns `None` rather than `NONE` so the
    dataset can skip the call entirely and a run with augmentation off
    costs nothing at all."""
    if name == "none":
        return None
    if name == "photometric":
        return PhotometricAugment()
    raise ValueError(f"unknown --augment {name!r}; expected 'none' or 'photometric'")
