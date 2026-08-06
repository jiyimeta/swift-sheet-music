"""Degradation chain (spec §6.5).

Stage contract -- this IS the architectural commitment the plan pins on
this module: a stage is a pure function

    (image: np.ndarray[uint8, (H, W)], rng: np.random.Generator, params: dict)
        -> (image: np.ndarray[uint8, (H, W)], homography: np.ndarray[(3, 3)] | None)

Geometric stages (those that move pixels around: resample, rotate, ...)
return their 3x3 pixel-space homography -- the forward map from THIS
STAGE'S OWN input pixel coordinates to its own output pixel coordinates
(that input may already be post-resample, post-rotate, etc. -- e.g.
`stage_rotate` centers its rotation on whatever `img.shape` it is
actually handed, not the original clean raster's shape). Photometric
stages (blur, noise, threshold, jpeg, ...) only change pixel VALUES,
never positions, and must return `None`. It is `apply_chain`, documented
below, that composes these per-stage matrices into the clean-raster ->
final map -- a future phone-stage author should read THIS map (a
stage's own input -> output), not assume any single stage already knows
about the whole chain.

`apply_chain` composes every stage's homography, in stage order, into one
3x3 matrix mapping the original clean-raster pixel to the final degraded
image's pixel. `freeze_eval_page` writes that composed matrix into the
page label's `image.label_transform` field (and only that field, plus
`image.file`) -- labels are never edited directly, only transformed as a
whole via this one matrix. This is also the phone-photo extension point:
a future phone profile is a sibling `.toml` that lists additional (possibly
new) stages; `load_profile` and `apply_chain` need no change to support
it, only a new stage function registered in `STAGES`. See
`Training/tests/test_degrade.py::test_new_geometric_stage_composes_through_unmodified_machinery`
for a worked demonstration.

Annotation overlay (pen strokes, circles, crosses, handwritten-looking
digits, highlighter bands) is noise for the detector to learn to REJECT,
not content to read -- `stage_annotation_overlay` never touches labels,
only pixels, and (like every photometric stage) returns `None`.
"""

import io
import json
import tomllib
from pathlib import Path
from typing import Callable

import numpy as np
from PIL import Image
from scipy import ndimage

Stage = Callable[[np.ndarray, np.random.Generator, dict], tuple[np.ndarray, np.ndarray | None]]


def _affine(a: float, b: float, tx: float, c: float, d: float, ty: float) -> np.ndarray:
    """Build a 3x3 homogeneous affine matrix `[[a, b, tx], [c, d, ty], [0, 0, 1]]`
    (row-major; operates on column vectors `(x, y, 1)^T`)."""
    return np.array([[a, b, tx], [c, d, ty], [0, 0, 1]], dtype=np.float64)


def _warp(img: np.ndarray, h: np.ndarray, out_shape: tuple[int, int] | None = None) -> np.ndarray:
    """Resample `img` through forward homography `h` (clean px -> output
    px) with a white (255) fill outside the source bounds. `out_shape` is
    `(rows, cols)` = `(height, width)`; defaults to `img.shape` (same
    canvas size). PIL's `Image.transform(..., AFFINE, coeffs)` samples via
    the INVERSE map (output px -> source px), so `h` is inverted once here."""
    inv = np.linalg.inv(h)
    out_shape = out_shape or img.shape
    pil = Image.fromarray(img)
    coeffs = (inv[0, 0], inv[0, 1], inv[0, 2], inv[1, 0], inv[1, 1], inv[1, 2])
    warped = pil.transform((out_shape[1], out_shape[0]), Image.Transform.AFFINE,
                           coeffs, resample=Image.Resampling.BILINEAR, fillcolor=255)
    return np.asarray(warped, dtype=np.uint8)


# --- Geometric stages (always return a homography) -------------------------

def stage_resample(img: np.ndarray, rng: np.random.Generator, p: dict):
    """DPI variation (uniform scale) plus a slight independent horizontal
    anisotropy, standing in for a scanner's non-square sampling grid."""
    s = rng.uniform(p.get("scale_lo", 0.92), p.get("scale_hi", 1.08))
    aniso = 1 + rng.uniform(-p.get("aniso_max", 0.02), p.get("aniso_max", 0.02))
    h = _affine(s * aniso, 0, 0, 0, s, 0)
    out_shape = (max(1, int(round(img.shape[0] * s))),
                 max(1, int(round(img.shape[1] * s * aniso))))
    return _warp(img, h, out_shape), h


def stage_rotate(img: np.ndarray, rng: np.random.Generator, p: dict):
    """Small skew (+-max_deg), rotating about the image center."""
    deg = rng.uniform(-p.get("max_deg", 2.0), p.get("max_deg", 2.0))
    t = np.deg2rad(deg)
    cy, cx = (img.shape[0] - 1) / 2, (img.shape[1] - 1) / 2
    c, s = np.cos(t), np.sin(t)
    # Rotate about the image center: T(c) . R . T(-c).
    h = (_affine(1, 0, cx, 0, 1, cy)
         @ _affine(c, -s, 0, s, c, 0)
         @ _affine(1, 0, -cx, 0, 1, -cy))
    return _warp(img, h), h


# --- Photometric stages (always return None) --------------------------------

def stage_erode_dilate(img: np.ndarray, rng: np.random.Generator, p: dict):
    """Randomly thins or thickens ink (toner spread / scanner threshold
    artifacts); a purely local intensity operation, no geometric shift.
    `elem_size` is the square structuring element's side length in
    pixels (default 2, matching the profile's recorded default)."""
    elem = p.get("elem_size", 2)
    size = (elem, elem)
    r = rng.random()
    if r < p.get("p_erode", 0.3):
        return ndimage.grey_erosion(img, size=size).astype(np.uint8), None
    if r < p.get("p_erode", 0.3) + p.get("p_dilate", 0.3):
        return ndimage.grey_dilation(img, size=size).astype(np.uint8), None
    return img, None


def stage_gaussian_blur(img: np.ndarray, rng: np.random.Generator, p: dict):
    sigma = rng.uniform(p.get("sigma_lo", 0.3), p.get("sigma_hi", 1.2))
    return ndimage.gaussian_filter(img, sigma=sigma).astype(np.uint8), None


def stage_noise(img: np.ndarray, rng: np.random.Generator, p: dict):
    """Sensor noise: additive Gaussian plus sparse salt-and-pepper."""
    out = img.astype(np.float64)
    out += rng.normal(0, p.get("gauss_sigma", 6.0), img.shape)
    sp = p.get("salt_pepper", 0.002)
    mask = rng.random(img.shape)
    out[mask < sp / 2] = 0
    out[(mask >= sp / 2) & (mask < sp)] = 255
    return np.clip(out, 0, 255).astype(np.uint8), None


def stage_illumination_gradient(img: np.ndarray, rng: np.random.Generator, p: dict):
    """Uneven scanner-bed / lid illumination: a linear brightness ramp
    along a randomly chosen axis."""
    drop = rng.uniform(0, p.get("max_drop", 0.15))
    axis = int(rng.integers(0, 2))
    ramp = np.linspace(1.0, 1.0 - drop, img.shape[axis])
    field = ramp[:, None] if axis == 0 else ramp[None, :]
    return np.clip(img.astype(np.float64) * field, 0, 255).astype(np.uint8), None


def stage_bleed_through(img: np.ndarray, rng: np.random.Generator, p: dict):
    """Ink show-through from the page's other side. A flipped, attenuated
    composite of THIS page's own ink is used as the "verso" (self-composite
    chosen over compositing a second page for determinism simplicity --
    it needs no extra corpus input and stays fully seed-reproducible)."""
    if rng.random() >= p.get("p", 0.5):
        return img, None
    verso = np.fliplr(img)
    alpha = p.get("alpha", 0.12)
    out = 255 - ((255 - img.astype(np.float64))
                 + alpha * (255 - verso.astype(np.float64)))
    return np.clip(out, 0, 255).astype(np.uint8), None


def stage_threshold(img: np.ndarray, rng: np.random.Generator, p: dict):
    """Occasional re-binarization, as some scanner drivers do by default.
    `thresh_lo`/`thresh_hi` bound the uniform draw for the binarization
    cut (defaults 120/200, matching the profile's recorded defaults)."""
    if rng.random() >= p.get("p", 0.3):
        return img, None
    thresh = rng.uniform(p.get("thresh_lo", 120), p.get("thresh_hi", 200))
    return np.where(img > thresh, 255, 0).astype(np.uint8), None


def stage_jpeg_roundtrip(img: np.ndarray, rng: np.random.Generator, p: dict):
    q = int(rng.integers(p.get("quality_lo", 55), p.get("quality_hi", 90) + 1))
    buf = io.BytesIO()
    Image.fromarray(img).save(buf, format="JPEG", quality=q)
    buf.seek(0)
    return np.asarray(Image.open(buf).convert("L"), dtype=np.uint8), None


_SEGMENTS = {  # 7-segment-style strokes for fingering-like handwritten digits, unit box
    1: [((0.8, 0.0), (0.8, 1.0))],
    2: [((0.0, 0.0), (1.0, 0.0)), ((1.0, 0.0), (1.0, 0.5)),
        ((1.0, 0.5), (0.0, 0.5)), ((0.0, 0.5), (0.0, 1.0)),
        ((0.0, 1.0), (1.0, 1.0))],
    3: [((0.0, 0.0), (1.0, 0.0)), ((1.0, 0.0), (1.0, 1.0)),
        ((0.0, 0.5), (1.0, 0.5)), ((0.0, 1.0), (1.0, 1.0))],
}


def _draw_line(img: np.ndarray, x0: int, y0: int, x1: int, y1: int, width: int, value: int) -> None:
    n = int(max(abs(x1 - x0), abs(y1 - y0))) + 1
    xs = np.linspace(x0, x1, n).round().astype(int)
    ys = np.linspace(y0, y1, n).round().astype(int)
    r = max(1, width // 2)
    for x, y in zip(xs, ys):
        img[max(0, y - r):y + r, max(0, x - r):x + r] = value


def stage_annotation_overlay(img: np.ndarray, rng: np.random.Generator, p: dict):
    """Handwritten-looking marks (pen strokes, circles, crosses,
    fingering-like digits, highlighter bands) drawn directly onto pixels.
    These are noise the detector must learn to reject, not content to
    read -- this stage NEVER edits labels (nor does any stage; only
    `freeze_eval_page` writes to a label file, and only its
    `image.label_transform` / `image.file` fields). A stroke mask, if
    ever needed as a side channel for a "reject annotation" auxiliary
    target, would be an additional return value on a THIRD position, not
    a label edit -- not implemented here as no consumer needs it yet."""
    if rng.random() >= p.get("p", 0.5):
        return img, None
    out = img.copy()
    h, w = out.shape
    for _ in range(int(rng.integers(1, p.get("max_marks", 6) + 1))):
        kind = rng.choice(["stroke", "circle", "cross", "digit", "highlight"])
        x = int(rng.integers(0, max(1, w - 60)))
        y = int(rng.integers(0, max(1, h - 60)))
        if kind == "stroke":
            _draw_line(out, x, y, x + int(rng.integers(20, 60)),
                       y + int(rng.integers(-20, 21)), 3, 60)
        elif kind == "cross":
            _draw_line(out, x, y, x + 20, y + 20, 3, 60)
            _draw_line(out, x + 20, y, x, y + 20, 3, 60)
        elif kind == "circle":
            t = np.linspace(0, 2 * np.pi, 60)
            r = int(rng.integers(10, 25))
            xs = (x + r + r * np.cos(t)).round().astype(int)
            ys = (y + r + r * np.sin(t)).round().astype(int)
            for cx, cy in zip(xs, ys):
                out[max(0, cy - 1):cy + 1, max(0, cx - 1):cx + 1] = 60
        elif kind == "digit":
            d = int(rng.choice(list(_SEGMENTS)))
            for (ax, ay), (bx, by) in _SEGMENTS[d]:
                _draw_line(out, x + int(ax * 12), y + int(ay * 18),
                           x + int(bx * 12), y + int(by * 18), 2, 60)
        else:  # highlighter band: darken a translucent bar
            band = out[y:y + 14, x:x + 80].astype(np.float64)
            out[y:y + 14, x:x + 80] = np.clip(band * 0.75, 0, 255).astype(np.uint8)
    return out, None


STAGES: dict[str, Stage] = {
    "resample": stage_resample,
    "rotate": stage_rotate,
    "erode_dilate": stage_erode_dilate,
    "gaussian_blur": stage_gaussian_blur,
    "noise": stage_noise,
    "illumination_gradient": stage_illumination_gradient,
    "bleed_through": stage_bleed_through,
    "annotation_overlay": stage_annotation_overlay,
    "threshold": stage_threshold,
    "jpeg_roundtrip": stage_jpeg_roundtrip,
}


def load_profile(path: Path) -> list[tuple[str, dict]]:
    """Read a degradation profile `.toml` (an ordered `[[stage]]` array of
    tables) into an ordered `(stage name, params)` list. Stage order in
    the file IS execution order -- `apply_chain` runs them as given, and
    the composed `label_transform` reflects that same order."""
    with open(path, "rb") as f:
        doc = tomllib.load(f)
    out = []
    for entry in doc["stage"]:
        params = {k: v for k, v in entry.items() if k != "name"}
        out.append((entry["name"], params))
    return out


def apply_chain(image: np.ndarray, profile: list[tuple[str, dict]],
                 rng: np.random.Generator) -> tuple[np.ndarray, np.ndarray]:
    """Run every `(name, params)` in `profile` against `STAGES[name]`, in
    order, threading a single `rng` through every stage (this is what
    makes the whole chain deterministic per seed). Returns the final
    degraded image and the COMPOSED 3x3 homography: the product of every
    geometric stage's matrix, later stage on the left, so that applying
    the result to a point in the ORIGINAL image reproduces applying each
    stage's transform in turn. Photometric stages (whose homography is
    `None`) contribute nothing to the composition -- they still run and
    still mutate the image, just not its geometry.
    """
    h_total = np.eye(3)
    img = image
    for name, params in profile:
        img, h = STAGES[name](img, rng, params)
        if h is not None:
            h_total = h @ h_total
    return img, h_total


def freeze_eval_page(png_path: Path, labels_path: Path, out_dir: Path,
                     profile: list[tuple[str, dict]], rng: np.random.Generator) -> None:
    """Frozen eval set (spec §6.5): degrade one clean page and write it
    plus its label file into `out_dir`. The label file is a copy of
    `labels_path`'s JSON with EXACTLY two fields rewritten --
    `image.file` (the degraded PNG's name) and `image.label_transform`
    (the composed homography from `apply_chain`, flattened row-major).
    Every other field is byte-for-byte the original decoded/re-encoded
    JSON. Unlike training-time degradation (applied fresh every epoch
    from the clean raster, unlimited variation), this is meant to be run
    ONCE per dataset version with a recorded seed, so eval numbers stay
    comparable across time -- calling this twice with fresh RNGs seeded
    identically must reproduce byte-identical output (see
    `test_freeze_eval_page_is_byte_identical_across_regenerations`)."""
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    img = np.asarray(Image.open(png_path).convert("L"), dtype=np.uint8)
    degraded, h = apply_chain(img, profile, rng)
    out_png = out_dir / Path(png_path).name
    Image.fromarray(degraded).save(out_png, format="PNG")
    labels = json.loads(Path(labels_path).read_text())
    labels["image"]["file"] = out_png.name
    labels["image"]["label_transform"] = [float(v) for v in h.reshape(-1)]
    (out_dir / Path(labels_path).name).write_text(
        json.dumps(labels, indent=2, sort_keys=True) + "\n")
