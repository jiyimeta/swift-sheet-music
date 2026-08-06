"""PDF → grayscale PNG (spec §6.4). pypdfium2: deterministic on one
host+version (the manifest's contract; cross-machine pixel identity is
NOT required). Color is not an axis for scanner-profile data.

Pixel/point coordinate contract (binds Task 16's label exporter): the
Swift side writes label coordinates in PDF page space (points, y-up,
bottom-left origin); this module rasterizes to images that are y-down,
top-left origin. Rendering uses `scale = dpi / 72` -- PDF canvas units
are points, 72 per inch -- which is exactly the mapping the plan fixes:

    x_pt = x_px * 72 / dpi
    y_pt = (H_px - y_px) * 72 / dpi

`H_px` MUST be the rendered image's actual pixel height (e.g. read back
from the PNG), not a value re-derived from page size + dpi independently
of the render call. pypdfium2 itself derives each axis's pixel size as
`math.ceil(page_size_pt * scale)` (see `PdfPage.render` in
`pypdfium2/_helpers/page.py`), and float imprecision in that product can
push the ceiling up by one pixel versus a naive `round(page_size_pt *
dpi / 72)` -- e.g. a 792pt page at 300dpi computes as
792.0 * (300/72) == 3300.0000000000005, one ULP above the exact integer,
so pdfium renders 3301px wide, not 3300. Reading the actual PNG
dimensions (rather than recomputing them) is what keeps the pixel<->point
mapping self-consistent regardless of that rounding quirk; see
`Training/tests/test_rasterize.py` for the numeric round-trip check.

Because the pixel size is always rounded UP to the next whole pixel, a
page whose points-to-pixels ratio isn't an integer (the common case) has
a sub-pixel sliver of blank padding along its top/right raster edges
that doesn't correspond to any point inside the PDF page -- e.g. an
842pt-tall page at 200dpi is exactly 2338.888...px tall but renders at
2339px, so the top ~0.11px of the raster is that padding. This is
expected and does not break the mapping's invertibility; it only means
a page-space point can map to a pixel row in [0, 1) rather than exactly
0 at the very top edge.

Which size to trust, for any consumer of this module: if a rendered
image already exists, READ ITS ACTUAL `.size` -- never recompute it.
`page_size_px` below exists only for the other case, predicting a
page's pixel size WITHOUT rendering it (e.g. writing a manifest's
width/height fields from a PDF's page-box points before or without
calling `rasterize_pdf`); it reproduces pdfium's exact ceiling rule, but
a real render is still the ground truth if one is available.
"""

import math
from pathlib import Path

import pypdfium2 as pdfium
from pypdfium2 import version as pdfium_version

DPI_GRID = [200, 300, 400]
DPI_NOMINAL = 300


def renderer_version() -> str:
    """Renderer identity string recorded into the manifest (Task 17)."""
    return f"pypdfium2 {pdfium_version.V_PYPDFIUM2}"


def page_size_px(width_pt: float, height_pt: float, dpi: int) -> tuple[int, int]:
    """Predict a page's rendered pixel size WITHOUT rendering it, using
    the exact rounding rule `PdfPage.render` applies internally
    (`math.ceil(size_pt * scale)`, `scale = dpi / 72`, same operand
    order -- see the module docstring for why operand order matters at
    fractional pixel sizes). Prefer reading a rendered image's actual
    `.size` whenever one exists; use this only when predicting ahead of
    or instead of a render (e.g. a manifest writer that has page-box
    points but no PNG in hand).
    """
    scale = dpi / 72
    return math.ceil(width_pt * scale), math.ceil(height_pt * scale)


def rasterize_pdf(pdf_path: Path, out_dir: Path, dpi: int) -> list[Path]:
    """Render every page of `pdf_path` to a grayscale PNG at `dpi`.

    Writes `page_<n>.png` (0-indexed, mode "L") into `out_dir` and
    returns the written paths in page order (index, not lexicographic --
    `page_10.png` must not sort before `page_2.png`). Rendering uses
    `scale = dpi / 72`, the fixed pixel/point relationship this module's
    docstring documents, so the dpi grid the plan specifies (`DPI_GRID`)
    is honored exactly.
    """
    pdf_path = Path(pdf_path)
    out_dir = Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    scale = dpi / 72

    doc = pdfium.PdfDocument(str(pdf_path))
    try:
        pages = []
        for index in range(len(doc)):
            page = doc[index]
            bitmap = page.render(scale=scale, grayscale=True)
            img = bitmap.to_pil()
            if img.mode != "L":
                img = img.convert("L")
            path = out_dir / f"page_{index}.png"
            img.save(path, format="PNG")
            pages.append((index, path))
    finally:
        doc.close()

    # Already sorted by construction (the loop above appends in
    # ascending `index` order); sort explicitly anyway so the numeric,
    # not-lexicographic order is guaranteed even if the loop above is
    # ever refactored to iterate out of order.
    pages.sort(key=lambda pair: pair[0])
    return [path for _, path in pages]
