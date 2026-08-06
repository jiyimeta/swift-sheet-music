import hashlib
import math
from pathlib import Path

import pypdfium2 as pdfium
from PIL import Image

from generate import rasterize


def _make_pdf(path: Path, pages: int = 2, size: tuple[float, float] = (595, 842)) -> None:
    doc = pdfium.PdfDocument.new()
    for _ in range(pages):
        doc.new_page(*size)
    doc.save(str(path))
    doc.close()


def test_page_size_px_matches_pdfium_ceil_formula_exactly(tmp_path):
    """`page_size_px` must reproduce the SAME formula pypdfium2's own
    `PdfPage.render` applies internally
    (`math.ceil(self.get_width() * scale)`, `scale = dpi / 72`), not an
    assumption about what "dpi" ought to mean. Verified against a real
    render (not just against itself) across a non-square page and every
    dpi in the grid, none of which divides 72 evenly."""
    width_pt, height_pt = 595, 842
    pdf = tmp_path / "s.pdf"
    _make_pdf(pdf, pages=1, size=(width_pt, height_pt))
    for dpi in rasterize.DPI_GRID:
        out = rasterize.rasterize_pdf(pdf, tmp_path / f"dpi{dpi}", dpi=dpi)
        img = Image.open(out[0])
        assert img.size == rasterize.page_size_px(width_pt, height_pt, dpi)


def test_page_size_px_ceils_not_rounds_at_an_exact_ratio():
    """Regression for the specific float-imprecision anomaly that first
    surfaced this rounding rule: 792pt at 300dpi has an EXACT ratio of
    3300.0, but `792.0 * (300 / 72)` evaluates in IEEE-754 double as
    3300.0000000000005 (one ULP high, since 300/72 isn't exactly
    representable) -- so pdfium (and this helper) render 3301px wide,
    not 3300. A naive `round()` would get this wrong; only `ceil` with
    the SAME operand order (`pt * (dpi / 72)`, not `pt * dpi / 72`)
    reproduces it."""
    assert rasterize.page_size_px(792, 612, 300) == (3301, 2550)


def test_rasterizes_every_page_grayscale_at_requested_dpi(tmp_path):
    pdf = tmp_path / "s.pdf"
    _make_pdf(pdf, pages=2)
    out = rasterize.rasterize_pdf(pdf, tmp_path, dpi=300)
    assert [p.name for p in out] == ["page_0.png", "page_1.png"]
    img = Image.open(out[0])
    assert img.mode == "L"
    # 595pt at 300dpi = 595/72*300 ≈ 2479 px (±1 for rounding).
    assert abs(img.width - round(595 / 72 * 300)) <= 1
    assert abs(img.height - round(842 / 72 * 300)) <= 1


def test_pixel_to_page_round_trip_on_non_square_page_at_uneven_dpi(tmp_path):
    """The fixed contract (task brief): a raster is y-down/top-left, a
    PDF page is y-up/bottom-left, so
        x_pt = x_px * 72 / dpi
        y_pt = (H_px - y_px) * 72 / dpi
    Verify the round trip numerically against an ACTUAL rendered image's
    height (not a height re-derived from page-size + dpi, which can
    differ by a pixel from what pdfium actually produced -- see the
    ceil-formula test above) on a non-square page at a dpi (200) where
    595pt/842pt does not divide evenly by 72."""
    width_pt, height_pt = 595, 842
    dpi = 200
    pdf = tmp_path / "s.pdf"
    _make_pdf(pdf, pages=1, size=(width_pt, height_pt))
    out = rasterize.rasterize_pdf(pdf, tmp_path, dpi=dpi)
    img = Image.open(out[0])
    h_px = img.height

    def page_to_pixel(x_pt: float, y_pt: float) -> tuple[float, float]:
        return x_pt * dpi / 72, h_px - y_pt * dpi / 72

    def pixel_to_page(x_px: float, y_px: float) -> tuple[float, float]:
        return x_px * 72 / dpi, (h_px - y_px) * 72 / dpi

    points = [
        (0.0, 0.0),
        (width_pt, height_pt),
        (123.4, 567.8),
        (width_pt / 2, height_pt / 2),
    ]
    for x_pt, y_pt in points:
        x_px, y_px = page_to_pixel(x_pt, y_pt)
        rt_x_pt, rt_y_pt = pixel_to_page(x_px, y_px)
        assert math.isclose(rt_x_pt, x_pt, rel_tol=0, abs_tol=1e-9)
        assert math.isclose(rt_y_pt, y_pt, rel_tol=0, abs_tol=1e-9)

    # And a corner sanity check against the image's own pixel grid: the
    # page's bottom-left point (0, 0) must land exactly on the raster's
    # bottom-left pixel row (y_px == h_px, since the y_pt term vanishes
    # there regardless of any rounding). The top-left page point
    # (0, height_pt) lands within one pixel of the raster's top row, NOT
    # necessarily exactly 0 -- pdfium's `ceil(height_pt * dpi / 72)`
    # pixel height is rounded UP from the page's exact height, so a
    # sub-pixel sliver of the raster's top edge (here, ~0.11px, since
    # 842pt @ 200dpi is 2338.888...px exact vs. 2339px actual) falls
    # outside any point that exists in page space. This confirms the
    # formula's y-flip direction (top-left page point maps near y_px=0,
    # not near y_px=h_px), not exact-zero landing.
    assert page_to_pixel(0.0, 0.0)[1] == h_px
    top_y_px = page_to_pixel(0.0, height_pt)[1]
    assert 0.0 <= top_y_px < 1.0


def test_same_input_same_bytes(tmp_path):
    pdf = tmp_path / "s.pdf"
    _make_pdf(pdf, pages=1)
    a = rasterize.rasterize_pdf(pdf, tmp_path / "a", dpi=200)
    b = rasterize.rasterize_pdf(pdf, tmp_path / "b", dpi=200)
    assert a[0].read_bytes() == b[0].read_bytes()


def test_same_input_same_bytes_across_dpi_grid(tmp_path):
    """Determinism must hold at every dpi the plan uses, not just one."""
    pdf = tmp_path / "s.pdf"
    _make_pdf(pdf, pages=1)
    for dpi in rasterize.DPI_GRID:
        a = rasterize.rasterize_pdf(pdf, tmp_path / f"a{dpi}", dpi=dpi)
        b = rasterize.rasterize_pdf(pdf, tmp_path / f"b{dpi}", dpi=dpi)
        assert hashlib.sha256(a[0].read_bytes()).digest() == hashlib.sha256(
            b[0].read_bytes()
        ).digest()


def test_pages_are_sorted_numerically_not_lexicographically(tmp_path):
    """10+ pages would sort "page_10.png" before "page_2.png" under a
    plain string sort; the return value must be page-index order."""
    pdf = tmp_path / "s.pdf"
    _make_pdf(pdf, pages=11)
    out = rasterize.rasterize_pdf(pdf, tmp_path, dpi=200)
    assert [p.name for p in out] == [f"page_{i}.png" for i in range(11)]


def test_renderer_version_names_the_tool():
    assert rasterize.renderer_version().startswith("pypdfium2 ")


def test_dpi_grid_and_nominal_match_the_plan():
    assert rasterize.DPI_GRID == [200, 300, 400]
    assert rasterize.DPI_NOMINAL == 300
    assert rasterize.DPI_NOMINAL in rasterize.DPI_GRID
