"""Reads a "prep root" written by the Swift export phase: per page,
`<render_id>/page_<n>.prep.json` beside `page_<n>.prep.png`. Indexes every
page under the root and decides which pages are train / val / test.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from pathlib import Path

from generate import vocabulary as _swift_vocabulary


@dataclass(frozen=True)
class Glyph:
    """One detector target on a page, in normalized pixels, y-down from
    the page's top-left.

    `origin_px` is the SMuFL registration point (what the score
    back-end is calibrated against), not a box corner; `advance_px` is
    the ink box's width and `rendered_size_px` its height.
    """
    class_name: str
    center_px: tuple[float, float]
    origin_px: tuple[float, float]
    advance_px: float
    rendered_size_px: float

    @staticmethod
    def from_json(data: dict) -> "Glyph":
        return Glyph(
            class_name=data["class"],
            center_px=tuple(data["center_px"]),
            origin_px=tuple(data["origin_px"]),
            advance_px=data["advance_px"],
            rendered_size_px=data["rendered_size_px"],
        )


@dataclass(frozen=True)
class ImageInfo:
    """The `image` block of a prep JSON: the normalized PNG's geometry
    and the scale/DPI it was rasterized at."""
    file: str
    width_px: int
    height_px: int
    staff_space_px: float
    scale: float
    source_width_px: int
    source_height_px: int
    source_dpi: float
    deskew_degrees: float

    @staticmethod
    def from_json(data: dict) -> "ImageInfo":
        return ImageInfo(
            file=data["file"],
            width_px=data["width_px"],
            height_px=data["height_px"],
            staff_space_px=data["staff_space_px"],
            scale=data["scale"],
            source_width_px=data["source_width_px"],
            source_height_px=data["source_height_px"],
            source_dpi=data["source_dpi"],
            deskew_degrees=data["deskew_degrees"],
        )


@dataclass(frozen=True)
class PrepPage:
    """One page of the prep root: `render_id/page_<page_index>.prep.json`
    plus the sibling `.prep.png` it describes."""
    render_id: str
    source_id: str
    face: str
    page_index: int
    png_path: Path
    image: ImageInfo
    glyphs: list[Glyph]

    @staticmethod
    def from_json_file(path: Path) -> "PrepPage":
        data = json.loads(path.read_text(encoding="utf-8"))
        image = ImageInfo.from_json(data["image"])
        return PrepPage(
            render_id=data["render_id"],
            source_id=data["source_id"],
            face=data["face"],
            page_index=data["page_index"],
            png_path=path.parent / image.file,
            image=image,
            glyphs=[Glyph.from_json(g) for g in data["glyphs"]],
        )


class PrepIndex:
    """Every page found under a prep root (`<render_id>/page_<n>.prep.json`),
    indexed in sorted, deterministic file order."""

    def __init__(self, root: Path):
        self.root = Path(root)
        self.pages: list[PrepPage] = [
            PrepPage.from_json_file(path)
            for path in sorted(self.root.glob("*/*.prep.json"))
        ]


def split_of(source_id: str, page_index: int, seed: int) -> str:
    """Which split a page belongs to.

    Keyed on (source_id, page_index) and NOT on the render, because the
    same source is rendered under eight faces and three dpi: a
    render-level split would put the identical engraved content on both
    sides. Keyed on the page and not on the source because the coverage
    generators build one source per family — holding out `cov_ornaments`
    would delete a family's classes from training entirely.

    A pure function of its inputs (sha256, never Python's salted
    `hash()`), so the split needs no stored file and is reproducible
    across processes and runs.
    """
    digest = hashlib.sha256(
        f"{seed}:{source_id}:{page_index}".encode()).digest()
    bucket = int.from_bytes(digest[:4], "big") % 100
    if bucket < 80:
        return "train"
    return "val" if bucket < 90 else "test"


#: The detector vocabulary, DERIVED from the frozen, append-only
#: `generate.vocabulary.CLASS_NAMES` minus `UNREACHABLE` (the classes no
#: SMuFL glyph exists for, so no detector box can ever be drawn for
#: them). Order is preserved from CLASS_NAMES. Never retyped here, so the
#: two lists cannot drift.
VOCABULARY: list[str] = [
    name for name in _swift_vocabulary.CLASS_NAMES
    if name not in _swift_vocabulary.UNREACHABLE
]

#: Detector class name -> contiguous class index, in VOCABULARY order.
CLASS_INDEX: dict[str, int] = {name: i for i, name in enumerate(VOCABULARY)}
