"""Canonical labels -> COCO detection format (spec §7.1 judgment call:
COCO is a CONVENIENCE EXPORT for off-the-shelf tooling; the canonical
JSON is authoritative -- COCO cannot carry paths, curves, origins, or
advances). Pixel space is y-down top-left; labels are y-up points.

Pixel-dimension contract (binds `rasterize.py`'s own docstring): an
image's actual pixel width/height -- both the COCO `images[].width` /
`.height` fields and the height used to y-flip every glyph bbox -- MUST
come from the rendered PNG's actual `.size` when one exists on disk.
`round(page_pt * dpi/72)` is NOT equivalent to pdfium's real
`ceil(page_pt * (dpi/72))` rule (they disagree whenever the float product
lands close to, but not on, a whole pixel -- see
`rasterize.page_size_px`'s docstring and
`Training/tests/test_rasterize.py::test_page_size_px_ceils_not_rounds_at_an_exact_ratio`),
and re-deriving the height at all -- rather than reading it back -- is
the deeper error: it silently offsets every annotation whenever the
recomputed value disagrees with what was actually rendered (e.g. a page
that passed through a geometric degradation stage in `degrade.py`
genuinely has different pixel dimensions than its page-box points would
predict). `_page_pixel_size` below reads the PNG's actual size first and
falls back to `rasterize.page_size_px` (the same verified ceil rule)
only when no rendered image exists yet for that page.

TWO heights, not one (whole-branch review, Important 2). The rule above
governs `images[].width` / `.height` -- the record of the file a
detector will actually open. The y-FLIP is a different question with a
different answer whenever `image.label_transform` is not the identity:
that homography maps CLEAN-raster pixels to DEGRADED pixels (see
`degrade.apply_chain`), so its input must be expressed in clean-raster
pixels, and the flip has to be anchored to the CLEAN raster's height.
Anchoring it to the degraded image's height instead offsets every
annotation on the page by the difference -- with `stage_resample`'s
default `s` in [0.92, 1.08], a 3509px A4 page degraded to 3228px lands
roughly `0.92 * 281 ~= 259px` off, on every glyph. `_clean_raster_size`
supplies that height: `image.source_size_px`, which `freeze_eval_page`
records from the clean PNG it actually read, else the same
`rasterize.page_size_px` derivation. When the transform IS the identity
the two heights are the same raster, and the actual-PNG rule applies to
both.

Which directories are exported: one that owns any of `_RENDER_MARKERS`.
`render.json` is the training pipeline's "this render completed" marker
(`build_dataset._render_dirs` keys off exactly it); `frozen.json` is the
frozen eval set's (spec 6.5), written by `build_dataset.freeze_dataset`,
because `freeze_eval_page` deliberately writes no `render.json` -- that
is what keeps a second `freeze` from re-degrading its own output. Before
`frozen.json` existed, `coco --root $R/eval_frozen` matched nothing and
emitted an empty COCO file without a word, so the frozen eval set had no
working path to the only detector-consumable format at all. A directory
with neither marker (a half-written render) stays invisible.
"""

import json
from pathlib import Path

import numpy as np
from PIL import Image

from generate import rasterize, vocabulary

# A directory is exported if it owns ANY of these -- see module docstring.
_RENDER_MARKERS = ("render.json", "frozen.json")


def _category_id(cls: str) -> int | None:
    try:
        return vocabulary.CLASS_NAMES.index(cls) + 1  # COCO ids 1-based
    except ValueError:
        return None  # reserved / unknown classes are not detector targets


def _page_pixel_size(render_dir: Path, doc: dict) -> tuple[int, int]:
    """(width_px, height_px) ground truth for one page's `image.file`.
    Prefers reading the actual rendered PNG's own pixel size from disk;
    falls back to `rasterize.page_size_px` (the verified `ceil` rule,
    NOT `round`) only when the file does not exist yet -- see module
    docstring."""
    img_path = render_dir / doc["image"]["file"]
    if img_path.exists():
        with Image.open(img_path) as im:
            return im.size  # (width, height) -- actual ground truth
    dpi = doc["image"]["dpi"]
    return rasterize.page_size_px(
        doc["page"]["width_pt"], doc["page"]["height_pt"], dpi)


def _clean_raster_size(doc: dict) -> tuple[int, int]:
    """(width_px, height_px) of the CLEAN raster this page's label
    coordinates were measured against -- the space `label_transform`
    maps FROM, and therefore the only correct anchor for the y-flip on a
    degraded page (see module docstring).

    `image.source_size_px` is authoritative when present: `freeze_eval_page`
    writes it from the clean PNG it actually opened, which is ground
    truth in the same sense reading the rendered PNG's `.size` is. The
    page-box derivation is the fallback for a label file written before
    that field existed; it reproduces pdfium's exact `ceil` rule, so it
    agrees with the real render except where the render itself was
    produced some other way."""
    recorded = doc["image"].get("source_size_px")
    if recorded:
        return int(recorded[0]), int(recorded[1])
    return rasterize.page_size_px(
        doc["page"]["width_pt"], doc["page"]["height_pt"], doc["image"]["dpi"])


def labels_to_coco(root: Path) -> dict:
    images, annotations = [], []
    image_id, ann_id = 0, 0
    for render_dir in sorted(Path(root).iterdir()):
        if not any((render_dir / marker).exists() for marker in _RENDER_MARKERS):
            continue
        for label_path in sorted(render_dir.glob("page_*.labels.json")):
            doc = json.loads(label_path.read_text())
            dpi = doc["image"]["dpi"]
            scale = dpi / 72.0
            width_px, height_px = _page_pixel_size(render_dir, doc)
            image_id += 1
            images.append({
                "id": image_id,
                "file_name": f"{render_dir.name}/{doc['image']['file']}",
                "width": width_px, "height": height_px,
            })
            transform = np.array(doc["image"]["label_transform"]).reshape(3, 3)
            identity = np.allclose(transform, np.eye(3))
            # Identity: the image on disk IS the raster the labels were
            # measured against, so the actual-PNG rule covers both uses.
            # Non-identity: `transform` expects clean-raster pixels.
            flip_height = height_px if identity else _clean_raster_size(doc)[1]
            for g in doc["glyphs"]:
                cat = _category_id(g["class"])
                if cat is None or g.get("bbox_pt") is None:
                    continue
                x0, y0, x1, y1 = g["bbox_pt"]
                # y-up pt -> y-down px, anchored to the ACTUAL pixel
                # height of the raster these coordinates belong to
                # (`flip_height`) -- never a recomputed
                # `height_pt * scale`, and never the degraded image's
                # height on a transformed page (see module docstring).
                corners = np.array([
                    [x0 * scale, flip_height - y1 * scale, 1],
                    [x1 * scale, flip_height - y1 * scale, 1],
                    [x0 * scale, flip_height - y0 * scale, 1],
                    [x1 * scale, flip_height - y0 * scale, 1],
                ]).T
                if not identity:
                    corners = transform @ corners
                    corners /= corners[2]
                xs, ys = corners[0], corners[1]
                x, y = float(xs.min()), float(ys.min())
                w, h = float(xs.max() - xs.min()), float(ys.max() - ys.min())
                ann_id += 1
                annotations.append({
                    "id": ann_id, "image_id": image_id, "category_id": cat,
                    "bbox": [x, y, w, h], "area": w * h, "iscrowd": 0,
                })
    categories = [{"id": i + 1, "name": name}
                  for i, name in enumerate(vocabulary.CLASS_NAMES)]
    return {"images": images, "annotations": annotations, "categories": categories}


def dump_coco(doc: dict, out_path: Path) -> Path:
    """Serialize an already-built COCO dict. Split out of `write_coco`
    so a caller that wants to inspect what it exported (the `coco`
    subcommand warns when a root yields zero images) does not have to
    walk the dataset twice or re-read the file it just wrote."""
    out_path = Path(out_path)
    out_path.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n")
    return out_path


def write_coco(root: Path, out_path: Path) -> Path:
    return dump_coco(labels_to_coco(root), out_path)
