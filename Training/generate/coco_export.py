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
"""

import json
from pathlib import Path

import numpy as np
from PIL import Image

from generate import rasterize, vocabulary


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


def labels_to_coco(root: Path) -> dict:
    images, annotations = [], []
    image_id, ann_id = 0, 0
    for render_dir in sorted(Path(root).iterdir()):
        if not (render_dir / "render.json").exists():
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
            for g in doc["glyphs"]:
                cat = _category_id(g["class"])
                if cat is None or g.get("bbox_pt") is None:
                    continue
                x0, y0, x1, y1 = g["bbox_pt"]
                # y-up pt -> y-down px, anchored to the ACTUAL pixel
                # height (height_px) read/derived above -- never a
                # recomputed `height_pt * scale` (see module docstring).
                corners = np.array([
                    [x0 * scale, height_px - y1 * scale, 1],
                    [x1 * scale, height_px - y1 * scale, 1],
                    [x0 * scale, height_px - y0 * scale, 1],
                    [x1 * scale, height_px - y0 * scale, 1],
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


def write_coco(root: Path, out_path: Path) -> Path:
    out_path = Path(out_path)
    out_path.write_text(json.dumps(labels_to_coco(root), indent=2, sort_keys=True) + "\n")
    return out_path
