"""MuseScore-3.02 XML primitives shared by the score generators.

Split out of `gen_coverage` when the coverage families grew past the
point where the document builder and the families fit in one readable
file. Every shape here is cross-checked against this repo's own MSCX
encoder/decoder (`Sources/SheetMusicMSCX/{Encoders,Decoders}/*.swift`),
the GPL-3.0 fixtures under `Tests/SheetMusicTests/Resources/` (read only
for schema shape, never copied -- see "Things not to do" in CLAUDE.md),
or upstream MuseScore's own engraving source (studied, never vendored):

- `<dots>` precedes `<durationType>` inside `<Chord>`. Documented in
  MSCXEncoder+NoteDuration.swift as load-bearing: MuseScore Studio's own
  writer emits it this way, and the reverse order makes MuseScore's
  loader silently drop the dot (renders as dotted, plays back as plain).
- `<Marker>` / `<Jump>` / `<startRepeat>` / `<endRepeat>` /
  `<LayoutBreak>` are children of `<Measure>`, siblings of `<voice>` --
  NOT nested inside `<voice>`. Confirmed by MSCXDecoder+Measure.swift,
  which reads Marker/Jump via `node.all("Marker")` / `node.all("Jump")`
  on the Measure node itself and startRepeat/endRepeat off its direct
  children (`MSCXDecoder+Measure.swift:45-46`), and by
  Tests/SheetMusicTests/Resources/repeat52.mscx:158-159, where MuseScore
  itself writes `<endRepeat>` before `<voice>`.
- Marker/Jump `<style>` uses the real MuseScore text-style tokens seen in
  repeat52.mscx ("Repeat Text Left" / "Repeat Text Right"), not an
  invented name.
- A tie's `<Spanner type="Tie"><next|prev><location>` payload carries
  `<measures>` (present only when the tie crosses a barline) plus a
  `<fractions>` magnitude whose sign depends on BOTH which side (start
  vs stop) AND whether it's same-bar or cross-bar -- see
  MSCXEncoder+Voice+Ties.swift's forwardTieLocation/backwardTieLocation
  and the `chord()` docstring below. Cross-checked against a real
  MuseScore-written cross-measure tie in Tests/SheetMusicTests/Resources/
  musicxml/testUnterminatedTies_ref.mscx:188-198,211-221.
- A common/cut time signature is a plain `<sigN>`/`<sigD>` `<TimeSig>`
  plus a leading `<subtype>` integer (MuseScore's `TimeSigType` enum
  ordinal: 1 = common/four-four "C", 2 = alla breve/cut "cut-C"),
  written before `<sigN>`/`<sigD>`. This element/ordering is not present
  anywhere in this repo's own Sources or fixtures (this package's model
  has no notion of the glyph-choice subtype at all) -- confirmed instead
  directly against upstream MuseScore's own engraving source
  (`TWrite::write(const TimeSig*, ...)` in twrite.cpp writes
  `Pid::TIMESIG_TYPE` -- XML name "subtype" -- before sigN/sigD;
  `TRead::read(TimeSig*, ...)` in read400/tread.cpp reads it back the
  same way for `mscVersion() > 114`, and MS3's own read206.cpp delegates
  to that same read400 TimeSig reader, so this is shared by both native
  MS3 and MS4).
- `<BeamMode>no</BeamMode>` is a `<Chord>` child. Token read out of
  upstream `src/engraving/types/typesconv.cpp`'s `BEAMMODE_TYPES`
  (`{ BeamMode::NONE, "no" }`); the element name comes from
  `twrite.cpp`'s `xml.tag("BeamMode", TConv::toXml(item->beamMode()))`.
  This package's decoder ignores the element (beaming is recomputed), so
  it is engraving-only -- which is exactly what a flag-coverage source
  needs.
- `<bracket type="1" span="2" col="0" visible="1"/>` plus
  `<barLineSpan>1</barLineSpan>` on the FIRST staff of a multi-staff
  `<Part>` is the grand-staff brace. `type="1"` is
  `BracketType.brace` (Sources/SheetMusicCore/Score/BracketItem.swift:8);
  the pair is exactly what MuseScore writes in
  Tests/SheetMusicTests/Resources/testMeasureRepeats.mscx:26-38.
- `<Clef><concertClefType>TOKEN</concertClefType></Clef>` inside
  `<voice>` is a mid-score clef change (harmony-basic.mscx:23). The token
  vocabulary is the same `ClefType` one `<defaultClef>` uses, so the
  silent-fallback trap documented on `gen_coverage._CLEFS` applies here
  too.

Nothing in this module is MuseScore-version-specific beyond the 3.02
document header: MuseScore 4 reads the MS3 schema through its compat
reader, and the MS3 arm of the face matrix reads it natively.
"""

from dataclasses import dataclass, field


@dataclass
class StaffSpec:
    """One staff of a part: its default clef and its measures.

    `measure_siblings` is index-aligned with `measures` and holds extra
    XML injected as a sibling of `<voice>` inside that `<Measure>`
    (Marker / Jump / startRepeat / endRepeat / LayoutBreak). A missing or
    empty entry means none.
    """
    clef: str = "G"
    measures: list[str] = field(default_factory=list)
    measure_siblings: list[str] = field(default_factory=list)


@dataclass
class PartSpec:
    """One `<Part>`. Staff 1 is described inline; `extra_staves` adds
    staves 2..N to the SAME part, which is what a grand staff is.

    `braced=True` draws the curly brace spanning the part's staves. It is
    a property of the part rather than of a staff because the brace's
    span is the part's staff count.
    """
    name: str
    clef: str = "G"
    measures: list[str] = field(default_factory=list)
    measure_siblings: list[str] = field(default_factory=list)
    extra_staves: list[StaffSpec] = field(default_factory=list)
    braced: bool = False

    @property
    def staves(self) -> list[StaffSpec]:
        first = StaffSpec(clef=self.clef, measures=self.measures,
                          measure_siblings=self.measure_siblings)
        return [first, *self.extra_staves]


def _part_staff_block(staff: StaffSpec, staff_id: int, *,
                      brace_span: int, spans_barline: bool) -> str:
    """The `<Staff>` block inside `<Part>` -- clef default and brackets.
    Distinct from the `<Staff>` block at Score level, which carries the
    measures."""
    lines = [f'      <Staff id="{staff_id}">',
             '        <StaffType group="pitched">',
             "          <name>stdNormal</name>",
             "        </StaffType>"]
    if brace_span:
        lines.append(
            f'        <bracket type="1" span="{brace_span}" col="0" visible="1"/>')
    if spans_barline:
        lines.append("        <barLineSpan>1</barLineSpan>")
    if staff.clef != "G":
        lines.append(f"        <defaultClef>{staff.clef}</defaultClef>")
    lines.append("      </Staff>")
    return "\n".join(lines)


def _score_staff_block(staff: StaffSpec, staff_id: int) -> str:
    measure_blocks = []
    for idx, body in enumerate(staff.measures):
        sibling = (staff.measure_siblings[idx]
                   if idx < len(staff.measure_siblings) else "")
        sibling_block = f"{sibling}\n" if sibling else ""
        measure_blocks.append(
            f"      <Measure>\n{sibling_block}"
            f"        <voice>\n{body}\n        </voice>\n"
            "      </Measure>")
    measures = "\n".join(measure_blocks)
    return f'    <Staff id="{staff_id}">\n{measures}\n    </Staff>'


def mscx_document(parts: list[PartSpec], division: int = 480) -> str:
    """Minimal MuseScore-3.02 document.

    Staff ids are assigned across the whole score, not per part, because
    the Score-level `<Staff>` blocks that carry the measures are a flat
    list -- a two-staff part occupies ids n and n+1.
    """
    part_blocks = []
    staff_blocks = []
    staff_id = 1
    for part in parts:
        staves = part.staves
        part_staff_blocks = []
        for offset, staff in enumerate(staves):
            part_staff_blocks.append(_part_staff_block(
                staff, staff_id + offset,
                brace_span=len(staves) if (part.braced and offset == 0) else 0,
                spans_barline=part.braced and offset < len(staves) - 1,
            ))
            staff_blocks.append(_score_staff_block(staff, staff_id + offset))
        staff_id += len(staves)
        part_blocks.append(
            "    <Part>\n"
            + "\n".join(part_staff_blocks) + "\n"
            + f"      <trackName>{part.name}</trackName>\n"
            + "      <Instrument>\n"
            + f"        <longName>{part.name}</longName>\n"
            + f"        <trackName>{part.name}</trackName>\n"
            + '        <Channel>\n          <program value="0"/>\n        </Channel>\n'
            + "      </Instrument>\n"
            + "    </Part>")
    return (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<museScore version="3.02">\n'
        "  <Score>\n"
        f"    <Division>{division}</Division>\n"
        "    <Style>\n      <Spatium>1.76389</Spatium>\n    </Style>\n"
        "    <showInvisible>1</showInvisible>\n"
        + "\n".join(part_blocks) + "\n"
        + "\n".join(staff_blocks) + "\n"
        "  </Score>\n"
        "</museScore>\n"
    )


def time_sig(n: int, d: int, subtype: int = 0) -> str:
    # `subtype` is MuseScore's TimeSigType ordinal: 0 = NORMAL (numeric,
    # the default -- omitted), 1 = FOUR_FOUR ("C" common-time glyph),
    # 2 = ALLA_BREVE ("cut-C" glyph). See module docstring for the
    # upstream evidence. Written before sigN/sigD, matching the writer.
    subtype_el = f"            <subtype>{subtype}</subtype>\n" if subtype else ""
    return (
        "          <TimeSig>\n"
        f"{subtype_el}"
        f"            <sigN>{n}</sigN>\n"
        f"            <sigD>{d}</sigD>\n"
        "          </TimeSig>"
    )


def chord(pitch: int, tpc: int, duration: str = "quarter", dots: int = 0,
          accidental: str | None = None, tie: str | None = None,
          tie_fraction: str = "1/4", tie_measures: int | None = None,
          head: str | None = None, stem: str | None = None,
          no_beam: bool = False, articulations: tuple[str, ...] = ()) -> str:
    """One `<Chord>` holding one `<Note>`.

    Element order mirrors MuseScore Studio's own writer: `<BeamMode>` and
    `<dots>` before `<durationType>` (see module docstring -- the reverse
    dot order makes MuseScore's loader silently drop the dot).

    `head` is a `NoteHead::Group` token (`"cross"` for the X noteheads);
    `stem` is `"up"` / `"down"`; `no_beam` emits
    `<BeamMode>no</BeamMode>` so a short note draws a FLAG rather than
    joining a beam group. `articulations` are SymId tokens
    (`"articStaccatoAbove"`, `"ornamentTrill"`, ...) -- MuseScore 3 files
    carry ornaments as `<Articulation>` too, which is why one argument
    covers both.
    """
    beam_el = "            <BeamMode>no</BeamMode>\n" if no_beam else ""
    dots_el = f"            <dots>{dots}</dots>\n" if dots else ""
    stem_el = f"            <StemDirection>{stem}</StemDirection>\n" if stem else ""
    artic_el = "".join(
        "            <Articulation>\n"
        f"              <subtype>{name}</subtype>\n"
        "            </Articulation>\n"
        for name in articulations)
    head_el = f"\n              <head>{head}</head>" if head else ""
    acc_el = (
        f"\n              <Accidental>\n                <subtype>{accidental}"
        "</subtype>\n              </Accidental>"
        if accidental else ""
    )
    # <location> = <measures> (present only when the tie crosses a
    # barline) + a signed <fractions> magnitude. Caller supplies both
    # fully formed -- see MSCXEncoder+Voice+Ties.swift's
    # forwardTieLocation/backwardTieLocation, which this mirrors:
    #   same-bar start:  fractions = +sourceDuration,           no <measures>
    #   cross-bar start: fractions = sourceDuration - barLength  (negative), <measures>1</measures>
    #   same-bar stop:   fractions = -prevChordDuration,        no <measures>
    #   cross-bar stop:  fractions = prevVoiceTotal - prevChordDuration (positive), <measures>-1</measures>
    # A single "-{tie_frac}" auto-negation (the earlier, buggy shape of
    # this helper) cannot express both same-bar and cross-bar stop signs
    # at once -- the cross-bar case needs a positive fraction and the
    # same-bar case needs a negative one -- so callers must pass the
    # correctly signed value per side instead.
    measures_el = (
        f"\n                    <measures>{tie_measures}</measures>"
        if tie_measures is not None else ""
    )
    if tie == "start":
        tie_el = (
            '\n              <Spanner type="Tie">\n                <Tie>\n'
            "                  </Tie>\n                <next>\n"
            f"                  <location>{measures_el}\n                    <fractions>{tie_fraction}"
            "</fractions>\n                  </location>\n                </next>\n"
            "                </Spanner>"
        )
    elif tie == "stop":
        tie_el = (
            '\n              <Spanner type="Tie">\n                <prev>\n'
            f"                  <location>{measures_el}\n                    <fractions>{tie_fraction}"
            "</fractions>\n                  </location>\n                </prev>\n"
            "                </Spanner>"
        )
    else:
        tie_el = ""
    return (
        "          <Chord>\n"
        f"{beam_el}{dots_el}"
        f"            <durationType>{duration}</durationType>\n"
        f"{stem_el}{artic_el}"
        "            <Note>\n"
        f"              <pitch>{pitch}</pitch>\n"
        f"              <tpc>{tpc}</tpc>{head_el}{acc_el}{tie_el}\n"
        "            </Note>\n"
        "          </Chord>"
    )


def rest(duration: str = "quarter") -> str:
    return (
        "          <Rest>\n"
        f"            <durationType>{duration}</durationType>\n"
        "          </Rest>"
    )


def measure_rest(n: int, d: int) -> str:
    """A rest that fills whatever the bar is, whatever its meter.

    `<duration>` accompanies `<durationType>measure</durationType>` in
    MuseScore's own output (harmony-basic.mscx:27), and
    `validate_mscx._voice_problems` charges the bar's full expected
    length for it. Drawn with the WHOLE-rest glyph, so a bar of these is
    also `restWhole` coverage.
    """
    return (
        "          <Rest>\n"
        "            <durationType>measure</durationType>\n"
        f"            <duration>{n}/{d}</duration>\n"
        "          </Rest>"
    )


def clef_change(clef: str) -> str:
    """Mid-score clef change, inside `<voice>` (harmony-basic.mscx:23).

    The first clef of a bar engraves full size, later ones cue size --
    both are the same detector class, and the size mix is deliberate
    detector diversity.
    """
    return (
        "          <Clef>\n"
        f"            <concertClefType>{clef}</concertClefType>\n"
        "          </Clef>"
    )


def dynamic(subtype: str) -> str:
    """`<Dynamic>` is a voice-level sibling of the chord it sits before
    (Tests/SheetMusicTests/Resources/testSingleNoteDynamics.mscx:96-99),
    NOT a `<Chord>` child. Multi-letter subtypes draw one glyph per
    letter ("mf" = dynamicMezzo + dynamicForte)."""
    return (
        "          <Dynamic>\n"
        f"            <subtype>{subtype}</subtype>\n"
        "          </Dynamic>"
    )


def fermata(subtype: str = "fermataAbove") -> str:
    return (
        "          <Fermata>\n"
        f"            <subtype>{subtype}</subtype>\n"
        "          </Fermata>"
    )


def marker(label: str, sym: str) -> str:
    """Measure-level sibling of `<voice>` -- see module docstring."""
    return (
        "        <Marker>\n"
        "          <style>Repeat Text Left</style>\n"
        f"          <text><sym>{sym}</sym></text>\n"
        f"          <label>{label}</label>\n"
        "        </Marker>"
    )


def jump(text: str, jump_to: str, play_until: str,
         continue_at: str = "") -> str:
    """Measure-level sibling of `<voice>`. `text` is inserted verbatim,
    so a caller can pass either plain text (`"D.C. al Fine"`, which
    MuseScore draws with the TEXT font) or a `<sym>` reference
    (`"<sym>daCapo</sym>"`, which draws the SMuFL glyph). The two are
    different pixels and different detector classes, so which one a
    source wants is a deliberate choice, not a formatting detail."""
    return (
        "        <Jump>\n"
        "          <style>Repeat Text Right</style>\n"
        f"          <text>{text}</text>\n"
        f"          <jumpTo>{jump_to}</jumpTo>\n"
        f"          <playUntil>{play_until}</playUntil>\n"
        f"          <continueAt>{continue_at}</continueAt>\n"
        "        </Jump>"
    )


def start_repeat() -> str:
    return "        <startRepeat/>"


def end_repeat(times: int = 2) -> str:
    return f"        <endRepeat>{times}</endRepeat>"


def layout_break(subtype: str = "line") -> str:
    """`<LayoutBreak><subtype>line</subtype></LayoutBreak>`, a Measure
    sibling (testMeasureRepeats.mscx:159-161 shows the element with
    subtype `nobreak`).

    Forcing the system breaks is what makes a per-system count -- the
    brace, above all -- deterministic instead of a function of the page
    size and spatium each face variant happens to draw.
    """
    return (
        "        <LayoutBreak>\n"
        f"          <subtype>{subtype}</subtype>\n"
        "        </LayoutBreak>"
    )
