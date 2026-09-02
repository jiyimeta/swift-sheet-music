import io
import xml.etree.ElementTree as ET
import zipfile

import pytest

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


# --- A source with no <Style> block --------------------------------------
#
# Whole-branch review, Important 3. `apply_style_mscx` used to `return
# text` unchanged when its regex found no `<Style>` block. The
# generators' own sources always carry one, but `--extra-sources` takes
# arbitrary user-authored scores -- which the runbook's step 1 tells the
# operator to pass. Such a score renders in MuseScore's default face
# while `dataset_plan.json` and `render.json` both record the REQUESTED
# face: metadata corruption on the one axis the whole dataset exists to
# vary, with no message anywhere. It also misdirects the face gate,
# whose `_face_font_check` is strict (`matched == checked`), so one bad
# source flips a whole face to `font-mismatch`.
#
# Note also what these tests are NOT: the file's determinism and
# idempotence tests are all of the form `f(f(x)) == f(x)` or
# `f(x) == f(x)`, which the identity function satisfies -- so a regex
# regression that stopped matching `<Style>` would leave them green.
# (`test_apply_style_rewrites_the_embedded_style_element` above does
# catch that, but nothing covered the no-block INPUT at all.)

def test_apply_style_raises_when_the_document_has_no_style_block():
    text = _sample_mscx().replace(
        "<Style>\n      <Spatium>1.76389</Spatium>\n    </Style>\n", "")
    assert "<Style>" not in text
    v = style_matrix.StyleVariant(face="Petaluma", spatium=1.8,
                                  page_w_in=8.27, page_h_in=11.69, engine="ms4")
    with pytest.raises(style_matrix.MissingStyleBlock):
        style_matrix.apply_style_mscx(text, v)


def test_apply_style_mscz_raises_when_no_inner_score_carries_a_style_block():
    stripped = _sample_mscx().replace(
        "<Style>\n      <Spatium>1.76389</Spatium>\n    </Style>\n", "")
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("score.mscx", stripped)
    v = style_matrix.StyleVariant(face="Petaluma", spatium=1.8,
                                  page_w_in=8.27, page_h_in=11.69, engine="ms4")
    with pytest.raises(style_matrix.MissingStyleBlock):
        style_matrix.apply_style_mscz(buf.getvalue(), v)


def test_apply_style_mscz_styles_the_scores_that_have_one_and_keeps_the_rest():
    """A real `.mscz` can hold several inner `.mscx` (excerpts / parts).
    Only the ones carrying a `<Style>` block are rewritten; the others
    are passed through verbatim rather than raising, because the face
    HAS been applied to the score that gets exported. Raising is reserved
    for the case where the style reached nothing at all."""
    styled = _sample_mscx()
    stripped = styled.replace(
        "<Style>\n      <Spatium>1.76389</Spatium>\n    </Style>\n", "")
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("score.mscx", styled)
        z.writestr("Excerpts/part.mscx", stripped)
    v = style_matrix.StyleVariant(face="Petaluma", spatium=1.8,
                                  page_w_in=8.27, page_h_in=11.69, engine="ms4")

    out = style_matrix.apply_style_mscz(buf.getvalue(), v)
    with zipfile.ZipFile(io.BytesIO(out)) as z:
        main = z.read("score.mscx").decode()
        part = z.read("Excerpts/part.mscx").decode()
    assert ET.fromstring(main).find(
        "Score/Style/musicalSymbolFont").text == "Petaluma"
    assert part == stripped


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


def test_apply_style_mscz_is_idempotent():
    # apply_style_mscx is independently proven idempotent
    # (test_apply_style_is_idempotent_and_deterministic); this proves the
    # composition -- unzip -> apply -> rezip -- doesn't reintroduce
    # nondeterminism (zip metadata, member ordering) on a second pass.
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        z.writestr("META-INF/container.xml",
                   '<?xml version="1.0"?><container><rootfiles>'
                   '<rootfile full-path="score.mscx"/></rootfiles></container>')
        z.writestr("score.mscx", _sample_mscx())
    v = style_matrix.StyleVariant(face="Bravura", spatium=1.76389,
                                  page_w_in=8.27, page_h_in=11.69, engine="ms4")
    once = style_matrix.apply_style_mscz(buf.getvalue(), v)
    twice = style_matrix.apply_style_mscz(once, v)
    assert once == twice


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
