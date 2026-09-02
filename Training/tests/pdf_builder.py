"""Hand-assembled minimal PDFs for tests.

Not a test module (no `test_` prefix, so pytest does not collect it):
shared support for `test_pdf_fonts.py` and `test_build_dataset.py`, both
of which need a PDF with a KNOWN embedded font name and known
`/ToUnicode` mapping. Everything is uncompressed and written byte by
byte, so no PDF-producing dependency is involved and the bytes under
test are exactly the bytes in this file.
"""

from pathlib import Path

#: /ToUnicode CMap mapping byte 0x41 -> U+E0A4 (noteheadBlack) and
#: 0x42 -> U+E050 (clefG) -- the PUA anchor real MuseScore output
#: carries, and what marks a run as MUSIC rather than text.
PUA_CMAP = b"""/CIDInit /ProcSet findresource begin
12 dict begin begincmap
1 begincodespacerange <00> <FF> endcodespacerange
2 beginbfchar
<41> <E0A4>
<42> <E050>
endbfchar
endcmap CMapName currentdict /CMap defineresource pop end end"""


def build_pdf(path, pages) -> Path:
    """Write a minimal PDF at `path`.

    `pages` is a list of pages; each page is a list of
    `(base_font, shown_text_bytes, to_unicode_cmap_or_None)` runs
    sharing that page -- the shape a real score page has, with the music
    font and the text font(s) side by side.
    """
    path = Path(path)
    objects: list[bytes | None] = [
        b"<</Type/Catalog/Pages 2 0 R>>",
        None,  # placeholder for the Pages node, needs the kid ids
    ]
    kid_ids = []
    for runs in pages:
        page_id = len(objects) + 1
        kid_ids.append(page_id)
        objects.append(None)  # placeholder: needs the font + contents ids
        font_ids = []
        for base_font, _shown, to_unicode in runs:
            font_id = len(objects) + 1
            font = b"<</Type/Font/Subtype/Type1/BaseFont/" + base_font.encode()
            if to_unicode is not None:
                # The CMap stream is appended immediately after this font.
                font += b"/ToUnicode " + str(font_id + 1).encode() + b" 0 R"
            objects.append(font + b">>")
            if to_unicode is not None:
                objects.append(b"<</Length " + str(len(to_unicode)).encode()
                               + b">>stream\n" + to_unicode + b"\nendstream")
            font_ids.append(font_id)
        contents_id = len(objects) + 1
        stream = b"".join(
            b"BT /F" + str(i + 1).encode() + b" 24 Tf 20 "
            + str(150 - i * 30).encode() + b" Td " + shown + b" Tj ET\n"
            for i, (_bf, shown, _tu) in enumerate(runs))
        objects.append(b"<</Length " + str(len(stream)).encode() + b">>stream\n"
                       + stream + b"\nendstream")
        resources = b"/Font<<" + b"".join(
            b"/F" + str(i + 1).encode() + b" " + str(fid).encode() + b" 0 R"
            for i, fid in enumerate(font_ids)) + b">>"
        objects[page_id - 1] = (
            b"<</Type/Page/Parent 2 0 R/MediaBox[0 0 200 200]/Resources<<"
            + resources + b">>/Contents " + str(contents_id).encode() + b" 0 R>>")
    objects[1] = (b"<</Type/Pages/Kids["
                  + b" ".join(f"{i} 0 R".encode() for i in kid_ids)
                  + b"]/Count " + str(len(kid_ids)).encode() + b">>")

    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for index, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += str(index).encode() + b" 0 obj" + body + b"endobj\n"
    xref_at = len(out)
    out += b"xref\n0 " + str(len(objects) + 1).encode() + b"\n"
    out += b"0000000000 65535 f \n"
    for offset in offsets:
        out += f"{offset:010d} 00000 n \n".encode()
    out += (b"trailer<</Size " + str(len(objects) + 1).encode()
            + b"/Root 1 0 R>>\nstartxref\n" + str(xref_at).encode() + b"\n%%EOF")
    path.write_bytes(bytes(out))
    return path


def music_pdf(path, font_name: str) -> Path:
    """One page, one music run in `font_name` (PUA-mapped) plus a text
    run, i.e. the minimum that looks like a rendered score page."""
    return build_pdf(path, [[
        (font_name, b"(AB)", PUA_CMAP),
        ("STUVWX+Edwin", b"(AB)", None),
    ]])
