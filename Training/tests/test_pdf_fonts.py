"""Hermetic: every PDF here is assembled byte by byte in `tmp_path`.
No MuseScore, no network, no fixture files."""

import pytest

from generate import pdf_fonts
from tests.pdf_builder import PUA_CMAP as _PUA_CMAP
from tests.pdf_builder import build_pdf as _build_pdf


def test_reports_the_base_font_name_including_its_subset_tag(tmp_path):
    """MuseScore embeds subsets, so the name carries a six-letter tag.
    It must survive to the caller -- the caller strips it deliberately,
    rather than pdfium having silently substituted something."""
    pdf = _build_pdf(tmp_path / "a.pdf",
                     [[("ABCDEF+Petaluma", b"(AB)", _PUA_CMAP)]])
    usage = pdf_fonts.font_usage(pdf)
    assert usage["music"] == {"ABCDEF+Petaluma": 2}
    assert usage["text"] == {}


def test_splits_music_from_text_by_pua_codepoint(tmp_path):
    """THE DISCRIMINATOR. One page carries both the music font and a
    text font; only the music font answers "which face rendered this".
    Membership in the private use area is what tells them apart -- no
    guessing from the font's name."""
    pdf = _build_pdf(tmp_path / "a.pdf", [[
        ("ABCDEF+Bravura", b"(AB)", _PUA_CMAP),      # 2 PUA glyphs
        ("GHIJKL+Edwin", b"(AB)", None),             # 2 plain letters
    ]])
    usage = pdf_fonts.font_usage(pdf)
    assert usage["music"] == {"ABCDEF+Bravura": 2}
    assert usage["text"] == {"GHIJKL+Edwin": 2}


def test_a_text_font_named_after_the_face_is_not_counted_as_music(tmp_path):
    """The trap this split exists to avoid: `musicalTextFont` is set to
    "<face> Text", so a face that silently fell back for its SYMBOL font
    would still show its own name among the PDF's fonts. Only the PUA
    chars decide."""
    pdf = _build_pdf(tmp_path / "a.pdf", [[
        ("ABCDEF+Bravura", b"(AB)", _PUA_CMAP),
        ("GHIJKL+PetalumaText", b"(AB)", None),
    ]])
    usage = pdf_fonts.font_usage(pdf)
    assert list(usage["music"]) == ["ABCDEF+Bravura"]
    assert "GHIJKL+PetalumaText" in usage["text"]


def test_music_is_empty_when_nothing_maps_into_the_pua(tmp_path):
    pdf = _build_pdf(tmp_path / "a.pdf", [[("Helvetica", b"(AB)", None)]])
    usage = pdf_fonts.font_usage(pdf)
    assert usage["music"] == {}
    assert usage["text"] == {"Helvetica": 2}


def test_max_pages_limits_the_walk(tmp_path):
    """One page is enough to see the music font, and a pilot has
    thousands of renders -- so the walk is capped by default."""
    pdf = _build_pdf(tmp_path / "a.pdf", [
        [("ABCDEF+Bravura", b"(AB)", _PUA_CMAP)],
        [("GHIJKL+Petaluma", b"(AB)", _PUA_CMAP)],
    ])
    assert pdf_fonts.font_usage(pdf, max_pages=1)["music"] == {"ABCDEF+Bravura": 2}
    assert set(pdf_fonts.font_usage(pdf, max_pages=None)["music"]) == {
        "ABCDEF+Bravura", "GHIJKL+Petaluma"}


def test_an_unreadable_pdf_yields_no_fonts_rather_than_raising(tmp_path):
    """A sweep over a dataset must not abort on one damaged file."""
    torn = tmp_path / "torn.pdf"
    torn.write_bytes(b"%PDF-1.4 not really\n%%EOF")
    assert pdf_fonts.font_usage(torn) == {"music": {}, "text": {}}
    assert pdf_fonts.font_usage(tmp_path / "absent.pdf") == {"music": {}, "text": {}}


@pytest.mark.parametrize("raw,expected", [
    ("ABCDEF+Petaluma", "Petaluma"),
    ("Petaluma", "Petaluma"),
    ("ABCDEF+Finale Maestro", "Finale Maestro"),
    # A tag is exactly six uppercase letters, so neither "AB" nor the
    # inner "+" qualifies and the name is left entirely alone.
    ("AB+CD+Bravura", "AB+CD+Bravura"),
    ("ABCDEF+GHIJKL+Bravura", "GHIJKL+Bravura"),  # only the LEADING tag
])
def test_strip_subset_tag(raw, expected):
    assert pdf_fonts.strip_subset_tag(raw) == expected


@pytest.mark.parametrize("raw,expected", [
    ("Finale Maestro", "finalemaestro"),
    ("ABCDEF+Petaluma", "petaluma"),
    ("MuseJazz-Regular", "musejazzregular"),
])
def test_normalize_font_name(raw, expected):
    assert pdf_fonts.normalize_font_name(raw) == expected
