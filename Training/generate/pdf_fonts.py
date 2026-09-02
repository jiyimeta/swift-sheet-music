"""Which fonts does a PDF actually draw with, split into music and text.

This is the POSITIVE half of gate P3c-G4. The geometry gate in
`build_dataset.faces_report` answers "are these two faces different from
each other"; this module answers the question the deferred decisions
actually ask -- "is this Petaluma?" -- by reading the name of the font
the renderer really embedded.

MUSIC vs TEXT: by PUA codepoint, never by the font's name. A render
carries several fonts (the symbol font, `musicalTextFont`, the lyric /
Edwin text font), and `style_matrix` sets `musicalTextFont` to
"<face> Text" -- so a face whose SYMBOL font silently fell back to
Bravura would still show its own name among the PDF's fonts. Only the
glyphs whose `/ToUnicode` maps into the private use area are music
glyphs, and the font drawing those is the face that actually rendered
the score. That is the same PUA anchor the Swift label export keys off
(`OMRLabelExport.invertCMaps` keeps PUA scalars only), so the two agree
by construction.

Measured against the pinned pypdfium2 4.30.0, with hand-built PDFs (see
`Training/tests/test_pdf_fonts.py`):

- `FPDFText_GetFontInfo` returns the `/BaseFont` name INCLUDING the
  six-letter subset tag MuseScore's embedding adds ("ABCDEF+Petaluma"),
  and does not substitute a different font for a name it cannot resolve
  -- so the name read back is the name the producer wrote, which is
  exactly what makes it usable as evidence. `strip_subset_tag` removes
  the tag deliberately at the point of comparison.
- `FPDFText_GetUnicode` resolves through `/ToUnicode`, so the PUA split
  above works on the real Type0 output.
- `FPDFFont_GetBaseFontName` does NOT exist in this build; the text-page
  entry point above is the supported route.
"""

import ctypes
import re
from pathlib import Path

import pypdfium2 as pdfium
import pypdfium2.raw as pdfium_c

#: BMP Private Use Area. SMuFL music glyphs live here, and MuseScore's
#: `/ToUnicode` maps its music codes into it.
PUA_FIRST = 0xE000
PUA_LAST = 0xF8FF

#: A subset tag is exactly six uppercase letters followed by "+".
_SUBSET_TAG_RE = re.compile(r"^[A-Z]{6}\+")
_NON_ALNUM_RE = re.compile(r"[^a-z0-9]+")

#: Per-page char cap. A page of music is a few thousand glyphs; this is
#: only a guard against a pathological file, never reached in practice.
MAX_CHARS_PER_PAGE = 20000


def strip_subset_tag(name: str) -> str:
    """"ABCDEF+Petaluma" -> "Petaluma". Only a LEADING six-letter tag is
    removed: a "+" elsewhere in a name is part of the name."""
    return _SUBSET_TAG_RE.sub("", name)


def normalize_font_name(name: str) -> str:
    """Case- and separator-insensitive form for comparing a font name
    against a face label ("Finale Maestro" -> "finalemaestro")."""
    return _NON_ALNUM_RE.sub("", strip_subset_tag(name).lower())


def _char_font_name(textpage_raw, index: int) -> str | None:
    """`FPDFText_GetFontInfo` for one character. Two calls: the first
    (null buffer) asks for the required size, the second fills it. The
    returned length counts the trailing NUL, which is dropped here."""
    flags = ctypes.c_int()
    needed = pdfium_c.FPDFText_GetFontInfo(
        textpage_raw, index, None, 0, ctypes.byref(flags))
    if needed <= 1:  # 0 = no font info; 1 = the NUL alone, i.e. empty
        return None
    buffer = ctypes.create_string_buffer(needed)
    written = pdfium_c.FPDFText_GetFontInfo(
        textpage_raw, index, buffer, needed, ctypes.byref(flags))
    if written <= 1:
        return None
    return buffer.raw[:written - 1].decode("utf-8", "replace")


def font_usage(pdf_path, max_pages: int | None = 1) -> dict[str, dict[str, int]]:
    """`{"music": {font name: glyph count}, "text": {...}}` for
    `pdf_path`, counting the first `max_pages` pages (`None` = all).

    Default `max_pages=1` because one page is enough to see which face
    rendered a score, and a pilot sweep opens thousands of PDFs.

    A file that cannot be opened yields empty counts rather than
    raising: this is called across a whole dataset, and one damaged PDF
    must not abort the sweep (the same reason `export_pdf.mscore_version`
    is best-effort).
    """
    usage: dict[str, dict[str, int]] = {"music": {}, "text": {}}
    try:
        document = pdfium.PdfDocument(str(Path(pdf_path)))
    except Exception:
        return usage
    try:
        limit = len(document) if max_pages is None else min(len(document), max_pages)
        for page_index in range(limit):
            page = document[page_index]
            textpage = page.get_textpage()
            try:
                count = min(textpage.count_chars(), MAX_CHARS_PER_PAGE)
                for char_index in range(count):
                    name = _char_font_name(textpage.raw, char_index)
                    if not name:
                        continue
                    codepoint = pdfium_c.FPDFText_GetUnicode(
                        textpage.raw, char_index)
                    bucket = ("music" if PUA_FIRST <= codepoint <= PUA_LAST
                              else "text")
                    usage[bucket][name] = usage[bucket].get(name, 0) + 1
            finally:
                textpage.close()
    except Exception:
        # A partially readable document still reports what it yielded.
        return usage
    finally:
        document.close()
    return usage
