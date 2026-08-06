import io
import xml.etree.ElementTree as ET
import zipfile

from generate import gen_coverage, style_matrix


def _sample_mscx() -> str:
    return gen_coverage.mscx_document([gen_coverage.PartSpec(
        name="P", measures=["\n".join([gen_coverage.time_sig(4, 4),
                                       gen_coverage.chord(60, 14)])])])


def _sample_mscx_with_extra_style() -> str:
    """A document whose <Style> block already carries a setting outside
    the five keys this module varies (mirrors a real MuseScore-authored
    score, e.g. one of the owner's original .mscz files, which write
    dozens of style fields we never touch)."""
    text = _sample_mscx()
    return text.replace(
        "<Style>\n      <Spatium>1.76389</Spatium>\n    </Style>",
        "<Style>\n      <Spatium>1.76389</Spatium>\n"
        "      <pagePrintableWidth>7.4826</pagePrintableWidth>\n    </Style>",
    )


def test_ms3_has_no_emmentaler_alias():
    assert "Emmentaler" not in style_matrix.FACES["ms3"]
    assert "MScore" in style_matrix.FACES["ms3"]


def test_ms4_has_no_emmentaler_alias():
    assert "Emmentaler" not in style_matrix.FACES["ms4"]
    assert "MScore" in style_matrix.FACES["ms4"]


def test_apply_style_rewrites_the_embedded_style_element():
    v = style_matrix.StyleVariant(face="Leland", spatium=1.9,
                                  page_w_in=8.27, page_h_in=11.69, engine="ms4")
    out = style_matrix.apply_style_mscx(_sample_mscx(), v)
    root = ET.fromstring(out)
    style = root.find("Score/Style")
    assert style.find("musicalSymbolFont").text == "Leland"
    assert style.find("musicalTextFont").text == "Leland Text"
    assert style.find("Spatium").text == "1.9"
    assert style.find("pageWidth").text == "8.27"
    assert style.find("pageHeight").text == "11.69"


def test_apply_style_translates_mscore_face_to_its_registered_font_name():
    # MuseScore's own default-style .mss files (every legacy version) and
    # engravingmodule.cpp both write/register the mscore.otf symbol font
    # under the internal name "Emmentaler", not "MScore" -- fontByName()
    # matches only the registered name, so writing "MScore" literally
    # would silently resolve to the fallback font (Leland) instead. The
    # face LABEL stays "MScore" (matches FACES / face_id / the manifest,
    # and matches musicalTextFont's family name "MScore Text"); only the
    # <musicalSymbolFont> value is translated.
    v = style_matrix.StyleVariant(face="MScore", spatium=1.76389,
                                  page_w_in=8.27, page_h_in=11.69, engine="ms3")
    out = style_matrix.apply_style_mscx(_sample_mscx(), v)
    style = ET.fromstring(out).find("Score/Style")
    assert style.find("musicalSymbolFont").text == "Emmentaler"
    assert style.find("musicalTextFont").text == "MScore Text"


def test_apply_style_translates_gootville_face_to_its_registered_font_name():
    # Same pattern: engravingmodule.cpp registers Gootville.otf under the
    # internal name "Gonville" (addMusicFont("Gonville", FontDataKey(u
    # "Gootville"), ...)); bracket.cpp / tlayout.cpp both gate legacy
    # bracket-shape logic on styleSt(Sid::musicalSymbolFont) == "Gonville",
    # confirming that's the value MuseScore itself compares against.
    v = style_matrix.StyleVariant(face="Gootville", spatium=1.76389,
                                  page_w_in=8.27, page_h_in=11.69, engine="ms4")
    out = style_matrix.apply_style_mscx(_sample_mscx(), v)
    style = ET.fromstring(out).find("Score/Style")
    assert style.find("musicalSymbolFont").text == "Gonville"
    assert style.find("musicalTextFont").text == "Gootville Text"


def test_apply_style_is_idempotent_and_deterministic():
    v = style_matrix.StyleVariant(face="Bravura", spatium=1.7,
                                  page_w_in=8.5, page_h_in=11.0, engine="ms4")
    once = style_matrix.apply_style_mscx(_sample_mscx(), v)
    assert style_matrix.apply_style_mscx(once, v) == once


def test_apply_style_preserves_unrelated_existing_style_settings():
    v = style_matrix.StyleVariant(face="Petaluma", spatium=1.8,
                                  page_w_in=8.27, page_h_in=11.69, engine="ms4")
    out = style_matrix.apply_style_mscx(_sample_mscx_with_extra_style(), v)
    style = ET.fromstring(out).find("Score/Style")
    assert style.find("pagePrintableWidth").text == "7.4826"
    assert style.find("musicalSymbolFont").text == "Petaluma"


def test_apply_style_mscz_roundtrips_the_container():
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("META-INF/container.xml",
                   '<?xml version="1.0"?><container><rootfiles>'
                   '<rootfile full-path="score.mscx"/></rootfiles></container>')
        z.writestr("score.mscx", _sample_mscx())
    v = style_matrix.StyleVariant(face="Gootville", spatium=1.76389,
                                  page_w_in=8.27, page_h_in=11.69, engine="ms3")
    out = style_matrix.apply_style_mscz(buf.getvalue(), v)
    with zipfile.ZipFile(io.BytesIO(out)) as z:
        inner = z.read("score.mscx").decode()
    assert "<musicalSymbolFont>Gonville</musicalSymbolFont>" in inner


def test_apply_style_mscz_is_deterministic():
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("META-INF/container.xml",
                   '<?xml version="1.0"?><container><rootfiles>'
                   '<rootfile full-path="score.mscx"/></rootfiles></container>')
        z.writestr("score.mscx", _sample_mscx())
    v = style_matrix.StyleVariant(face="Bravura", spatium=1.76389,
                                  page_w_in=8.27, page_h_in=11.69, engine="ms4")
    data = buf.getvalue()
    assert style_matrix.apply_style_mscz(data, v) == style_matrix.apply_style_mscz(data, v)


def test_variants_are_deterministic_and_engine_scoped():
    a = style_matrix.style_variants(seed=1, engine="ms4", per_face=2)
    assert a == style_matrix.style_variants(seed=1, engine="ms4", per_face=2)
    assert len(a) == 2 * len(style_matrix.FACES["ms4"])
    assert {style_matrix.face_id(v).split("/")[0] for v in a} == {"ms4"}
    assert all(1.5 <= v.spatium <= 2.2 for v in a)


def test_variants_ms3_is_engine_scoped_and_smaller():
    a = style_matrix.style_variants(seed=1, engine="ms3", per_face=3)
    assert len(a) == 3 * len(style_matrix.FACES["ms3"])
    assert {style_matrix.face_id(v).split("/")[0] for v in a} == {"ms3"}


def test_face_id_is_engine_qualified():
    v = style_matrix.StyleVariant(face="Leland", spatium=1.8,
                                  page_w_in=8.27, page_h_in=11.69, engine="ms4")
    assert style_matrix.face_id(v) == "ms4/Leland"
    v3 = style_matrix.StyleVariant(face="Leland", spatium=1.8,
                                   page_w_in=8.27, page_h_in=11.69, engine="ms3")
    assert style_matrix.face_id(v3) == "ms3/Leland"
