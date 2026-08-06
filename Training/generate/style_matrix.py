"""Style/face variation (spec §6.2). Font diversity is the decisive axis
for this whole training program: a prior measurement pinned the
font-independent glyph recognition bottleneck to shape descriptors not
being invariant across design languages, so a training set spanning
many faces is the point of the exercise.

`mscore -S style.mss` is SILENTLY IGNORED for headless PDF export
(measured trap) -- style must instead be rewritten into the score's own
embedded `<Style>` element: text-level surgery for `.mscx`, unzip / edit
inner `.mscx` / re-zip for `.mscz`. `apply_style_mscx` therefore edits
only the five target elements in place and leaves every other existing
`<Style>` child (margins, header/footer, swing, ...) untouched -- both
because it must not destroy a real MuseScore-authored score's other
settings when routed through `apply_style_mscz`, and because a
wholesale-block replace would be indistinguishable from "append a
second block" for anything downstream that greps rather than parses.

Ported from studying MuseScore's own GPL-3.0 source
(~/Developer/musescore/MuseScore) as a behavioural reference only -- no
code copied, no vendoring (see "MuseScore C++ source as reference" in
this repo's CLAUDE.md). Facts cited below by file name.

Element names, verified against a real source rather than assumed:

- `pageWidth` / `pageHeight`: present verbatim in this repo's own real
  fixture Tests/SheetMusicTests/Resources/repeat52.mscx:6-7, and decoded
  under those exact names by
  Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Style.swift.
- `Spatium` (capital S): this generator's own MS3-schema (version
  "3.02") documents (gen_coverage.mscx_document) already write capital
  `<Spatium>`, matching every capital-Spatium fixture under
  Tests/SheetMusicTests/Resources/ that also carries `version="3.01"`.
  Confirmed on the MuseScore side too: `read206.cpp:3316` (the MS3-era
  reader, still compiled into the modern binary as its own-version
  compat path) matches tag `"Spatium"`; `style.cpp`'s shared
  `MStyle::read` accepts `tag == "Spatium" || tag == "spatium"`
  regardless of `mscVersion`, and that same function is invoked by
  read302 / read400 / read410 / read460 alike via
  `ReadStyleHook::readStyleTag`. Since every source this module edits is
  the MS3-schema (`version="3.02"`) documents this repo's own generators
  emit, capital `Spatium` is written uniformly for both `engine` values
  -- there is no reader-side reason to vary the case per engine here
  (this repo's own MSCXEncoder+Style.swift *does* vary case by target
  version for its own v4-native writer output, but that's a different
  question -- what MuseScore Studio itself writes when saving a
  v4-schema file -- from what this module needs, which is "what does
  the shared reader accept inside a v3.02-schema document," and the
  answer there is unconditionally: both).
- `musicalSymbolFont` / `musicalTextFont`: not present in this repo's
  Sources or fixtures (ScoreStyle has no font-face concept), so verified
  against the MuseScore checkout instead. `styledef.cpp`'s
  `#define styleDef(sidAndXmlTag, property) { Sid::sidAndXmlTag,
  #sidAndXmlTag, property }` stringifies the enum identifier itself as
  the XML tag, so the two names are exact. Read generically (not
  special-cased) via `MStyle::read`'s `readProperties(e)` fallback,
  independent of `mscVersion` -- confirmed by `style.cpp` containing no
  `mscVersion`-gated branch for either tag.

Font *value* domain -- the two-name trap this task's brief warns is
easy to get wrong by "plausibility": naively writing the face label
into `<musicalSymbolFont>` is correct for six of the eight faces but
silently wrong for two:

- "MScore": `engravingmodule.cpp` registers the bundled mscore.otf under
  the internal lookup name `"Emmentaler"` --
  `addMusicFont("Emmentaler", FontDataKey(u"MScore"), ".../MScore.otf")`
  -- and every one of MuseScore's own legacy default-style files
  (`legacy-style-defaults-{v1,v2,v3}.mss`, i.e. the real defaults for
  MS 1.x/2.x/3.x alike) literally write
  `<musicalSymbolFont>Emmentaler</musicalSymbolFont>`.
  `EngravingFontsProvider::fontByName` (engravingfontsprovider.cpp)
  matches only the registered name case-insensitively; `"MScore"`
  itself matches nothing and silently falls back to the engine's
  fallback font instead of rendering MScore glyphs --
  `engravingmodule.cpp:224` sets that fallback to `"Bravura"`
  (`setFallbackFont("Bravura")`); "Leland" is a different mechanism
  entirely, the *style default* a brand-new score starts with
  (`styledef.cpp:590`), not what an unmatched lookup falls back to.
  This *is* the Emmentaler
  alias the task's hard facts warn about -- but the direction of the
  fix is the opposite of what a literal-substring read suggests: the
  face *label* everywhere in this module (FACES, face_id, the manifest)
  stays "MScore" per the interface contract and to prevent Emmentaler
  from ever appearing as if it were a distinct face; only the value
  written into `<musicalSymbolFont>` is translated to "Emmentaler" so
  the render actually uses the intended glyphs.
- "Gootville": same pattern. `engravingmodule.cpp` registers it as
  `addMusicFont("Gonville", FontDataKey(u"Gootville"),
  ".../Gootville.otf")` -- lookup name "Gonville", not "Gootville".
  Confirmed independently by two unrelated call sites that gate legacy
  bracket-shape logic on the literal style value:
  `dom/bracket.cpp:69` and `rendering/score/tlayout.cpp:1387` both
  compare `styleSt(Sid::musicalSymbolFont) == "Gonville"` (never
  "Gootville").
- `musicalTextFont` is unaffected by either translation: MuseScore's
  companion text font is registered under the *family* (on-disk
  product) name, not the lookup name --
  `fdb->addFont(FontDataKey(u"MScore Text"), ...)` and
  `fdb->addFont(FontDataKey(u"Gootville Text"), ...)` -- so
  `f"{face} Text"` (using the face label, not the translated symbol-font
  value) is correct for all eight faces, these two included. This is
  also how `editstyle.cpp`'s style dialog itself builds the value:
  `musicalTextFont->addItem(fontDisplayName + " Text",
  fontFamilyName + " Text")` populates from `family()`, while
  `musicalSymbolFont->addItem(fontDisplayName, fontDisplayName)`
  populates from `name()` -- two different fields of the same font
  registration, by design.

MS3 vs MS4 face tables: MS4 exposes all eight bundled faces (verified
present as font families in `~/Developer/musescore/MuseScore/fonts/`:
bravura, leland, gootville, musejazz, petaluma, mscore, finalemaestro,
finalebroadway -- rendering needs no font *files*, MuseScore renders
them from its own bundled resources). MS3 predates Leland (MuseScore
4's default face) and the two Finale-branded faces, so its face table
is the four that existed in the MS3 era: MScore (its own default),
Bravura, Gootville, MuseJazz. `FACES["ms3"]` intentionally omits
"Emmentaler" as a face name of its own (hard fact #2): it is the same
rendered glyphs as "MScore", and pooling them under two labels is
exactly the corpus-measurement bug this task exists to avoid (memory:
a naive distinct-string count once inflated a reported figure from
63.3% to 71.4%). `face_id` prefixes every variant with its `engine`
("ms3/…" / "ms4/…") specifically so a downstream manifest never pools
an MS3 render against an MS4 render under one bare face name, per hard
fact #4 (different engines, different default faces, different style
schemas) -- distinct engine builds are also the reproducibility anchor
for what "a face" concretely means, since the glyph outlines a face
resolves to are a property of the engine binary, not just the label.

Recorded limitation, matching the plan's own note (spec R2's
mitigation, not this task's): whether a face string actually *applies*
inside a real `mscore` invocation is verified downstream by the label
export census (PUA glyph population) and gate P3c-G4 (>=1 confirmed
render per face during the pilot). MS3 vs MS4 style-schema drift beyond
the five varied keys (face, spatium, page width, page height, plus the
symbol/text-font pairing) is deliberately not modeled.
"""

import io
import re
import zipfile
from dataclasses import dataclass

import numpy as np

FACES = {
    # Verified present as bundled font families in the local MuseScore
    # checkout's fonts/ dir; rendering needs no font files (Qt resource
    # blob) -- see module docstring.
    "ms4": ["Bravura", "Leland", "Gootville", "MuseJazz", "Petaluma",
            "MScore", "Finale Maestro", "Finale Broadway"],
    # MS3 predates Leland and the Finale-branded faces. "Emmentaler" is
    # deliberately absent -- see module docstring's hard-fact-#2 note.
    "ms3": ["MScore", "Bravura", "Gootville", "MuseJazz"],
}

# A4 (mm/INCH, matching styledef.cpp's own pageWidth/pageHeight default:
# 210/25.4 = 8.27, 297/25.4 = 11.69) and US Letter.
_PAGES = [(8.27, 11.69), (8.5, 11.0)]

# Face label -> the internal font-registration name MuseScore actually
# matches <musicalSymbolFont> against, for the two faces where that
# differs from the label. See module docstring for the citations
# (engravingmodule.cpp addMusicFont calls, legacy-style-defaults-*.mss,
# bracket.cpp / tlayout.cpp literal comparisons). Every other face's
# registration name equals its label, so this table only needs entries
# for the exceptions.
_SYMBOL_FONT_XML_VALUE = {
    "MScore": "Emmentaler",
    "Gootville": "Gonville",
}

# The five <Style> children this module owns. Only used to build
# _OWNED_TAGS_LOWER below (case-insensitive match, so a pre-existing
# lowercase "spatium" is matched via "Spatium".lower() without needing
# its own tuple entry) -- Spatium is always written back capitalized,
# see module docstring.
_OWNED_TAGS = ("Spatium", "musicalSymbolFont",
               "musicalTextFont", "pageWidth", "pageHeight")

_STYLE_BLOCK_RE = re.compile(r"<Style>(.*?)</Style>", re.DOTALL)


class MissingStyleBlock(ValueError):
    """No `<Style>` element to rewrite, so the requested face was NOT
    applied to this source.

    Raised rather than returning the text untouched (the old behavior).
    A silent no-op is the worst available outcome here: the score
    renders in MuseScore's default face while `dataset_plan.json` and
    `render.json` both record the face that was ASKED for, which is
    metadata corruption on the exact axis this dataset exists to vary --
    and it is invisible, because nothing downstream can read a font name
    out of a label file. It also misdirects gate P3c-G4: `_face_font_check`
    is strict (`matched == checked`), so one such source flips the whole
    face to `font-mismatch` and points the operator at a face that was
    applied correctly everywhere else.

    The generators' own sources always carry a `<Style>`; the reachable
    case is `--extra-sources`, which accepts arbitrary user-authored
    `.mscx` / `.mscz` (the runbook's step 1 tells the operator to pass
    exactly that). `build_dataset._write_source` catches this and
    quarantines the render, naming the offending source's origin so the
    operator can act on it.
    """


@dataclass(frozen=True)
class StyleVariant:
    face: str
    spatium: float
    page_w_in: float
    page_h_in: float
    engine: str


def face_id(v: StyleVariant) -> str:
    """Engine-qualified identity string ("ms4/Leland") so an MS3 render
    and an MS4 render of the same face label are never pooled as one
    face in a manifest (hard fact #4)."""
    return f"{v.engine}/{v.face}"


def style_variants(seed: int, engine: str, per_face: int) -> list[StyleVariant]:
    """`per_face` deterministic variants for every face in `FACES[engine]`.
    Same (seed, engine, per_face) -> byte-identical output; iteration
    order is `FACES[engine]`'s fixed list order, so nothing depends on
    unordered dict/set iteration."""
    rng = np.random.default_rng(seed)
    out: list[StyleVariant] = []
    for face in FACES[engine]:
        for _ in range(per_face):
            w, h = _PAGES[int(rng.integers(0, len(_PAGES)))]
            out.append(StyleVariant(
                face=face,
                spatium=round(float(rng.uniform(1.5, 2.2)), 5),
                page_w_in=w, page_h_in=h, engine=engine,
            ))
    return out


def _symbol_font_value(face: str) -> str:
    return _SYMBOL_FONT_XML_VALUE.get(face, face)


def _style_block_children(v: StyleVariant) -> str:
    text_face = f"{v.face} Text"
    symbol_font = _symbol_font_value(v.face)
    return (
        f"      <Spatium>{v.spatium}</Spatium>\n"
        f"      <musicalSymbolFont>{symbol_font}</musicalSymbolFont>\n"
        f"      <musicalTextFont>{text_face}</musicalTextFont>\n"
        f"      <pageWidth>{v.page_w_in}</pageWidth>\n"
        f"      <pageHeight>{v.page_h_in}</pageHeight>\n"
    )


_OWNED_TAGS_LOWER = {t.lower() for t in _OWNED_TAGS}
_OPEN_TAG_RE = re.compile(r"<(\w+)>")


def _other_style_lines(style_inner: str) -> list[str]:
    """Every line of a captured `<Style>...</Style>` inner region that
    is neither blank/whitespace-only nor one of the five tags this
    module owns, with its original text (indentation included)
    preserved verbatim. This is what makes `apply_style_mscx` a merge
    rather than a wholesale block replace: reconstructing from *kept*
    lines (rather than stripping owned ones out of the original text)
    keeps the result byte-identical across repeated application, since
    nothing about the previously-inserted whitespace can accumulate.

    Every `<Style>` child observed in this repo's fixtures and in this
    generator's own output is a single line; a hypothetical
    unrelated multi-line child is out of scope here (see module
    docstring's "Recorded limitation").
    """
    kept = []
    for line in style_inner.split("\n"):
        stripped = line.strip()
        if not stripped:
            continue
        m = _OPEN_TAG_RE.match(stripped)
        if m and m.group(1).lower() in _OWNED_TAGS_LOWER:
            continue
        kept.append(line)
    return kept


def apply_style_mscx(text: str, v: StyleVariant) -> str:
    """Rewrite the score's own embedded `<Style>` element in place
    (text-level surgery -- see module docstring on the `-S` trap).
    Idempotent: reapplying the same variant to already-styled text
    yields byte-identical output, because the result is rebuilt from
    "every other child, unchanged" plus "the five owned tags, freshly
    written" rather than by patching the previous text in place.
    Non-destructive: any other existing `<Style>` child is preserved
    verbatim (own line, own indentation), so this is safe to run on a
    real MuseScore-authored score (via `apply_style_mscz`) that carries
    many settings this module never varies.

    Raises `MissingStyleBlock` when the document has no `<Style>`
    element at all -- see that exception's docstring for why silence was
    the wrong answer.
    """
    match = _STYLE_BLOCK_RE.search(text)
    if match is None:
        raise MissingStyleBlock(
            "no <Style> element to rewrite, so face "
            f"{v.face!r} was not applied")
    lines = _other_style_lines(match.group(1))
    lines.append(_style_block_children(v).rstrip("\n"))
    new_inner = "\n" + "\n".join(lines) + "\n    "
    return text[:match.start()] + f"<Style>{new_inner}</Style>" + text[match.end():]


def apply_style_mscz(data: bytes, v: StyleVariant) -> bytes:
    """Unzip, rewrite every inner `*.mscx` via `apply_style_mscx`,
    re-zip deterministically (fixed timestamp, sorted names,
    `ZIP_DEFLATED`) so the same (data, v) always produces identical
    bytes.

    Per-member tolerance, whole-container strictness: a real `.mscz`
    can hold several inner `.mscx` (excerpts / parts), and one of them
    lacking a `<Style>` block does not mean the face went unapplied --
    the score that gets exported to PDF carries the style. So a member
    that raises `MissingStyleBlock` is passed through verbatim, and the
    exception is re-raised only if NO member was rewritten, which is the
    genuine "this face reached nothing" case.
    """
    src = zipfile.ZipFile(io.BytesIO(data))
    out_buf = io.BytesIO()
    styled = 0
    with zipfile.ZipFile(out_buf, "w", compression=zipfile.ZIP_DEFLATED) as out:
        for name in sorted(src.namelist()):
            payload = src.read(name)
            if name.endswith(".mscx"):
                try:
                    payload = apply_style_mscx(
                        payload.decode("utf-8"), v).encode("utf-8")
                    styled += 1
                except MissingStyleBlock:
                    pass  # keep this member as-is; see docstring
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            out.writestr(info, payload)
    if not styled:
        raise MissingStyleBlock(
            "no inner .mscx carried a <Style> element, so face "
            f"{v.face!r} was not applied to any score in this .mscz")
    return out_buf.getvalue()
