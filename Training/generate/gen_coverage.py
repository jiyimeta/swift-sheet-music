"""Coverage-score generator (spec §6.1.1): .mscx sources that exercise
rare detector classes so per-class floors (gate P3c-G3) are reachable.
MS3 (3.02) schema, written by our own template code. Deterministic:
all variation derives from the seed via numpy Generators.

XML shapes here are cross-checked against this repo's own MSCX
encoder/decoder (Sources/SheetMusicMSCX/{Encoders,Decoders}/*.swift) and
the GPL-3.0 fixtures under Tests/SheetMusicTests/Resources/ (read only
for schema shape, never copied — see "Things not to do" in CLAUDE.md):

- `<dots>` precedes `<durationType>` inside `<Chord>`. This order is
  documented in MSCXEncoder+NoteDuration.swift as load-bearing: MuseScore
  Studio's own writer emits it this way, and the reverse order makes
  MuseScore's loader silently drop the dot (renders as dotted, plays back
  as plain).
- `<Marker>` / `<Jump>` are children of `<Measure>`, siblings of
  `<voice>` — NOT nested inside `<voice>`. Confirmed by
  MSCXDecoder+Measure.swift, which reads them via `node.all("Marker")` /
  `node.all("Jump")` on the Measure node itself.
- Marker/Jump `<style>` uses the real MuseScore text-style tokens seen in
  Tests/SheetMusicTests/Resources/repeat52.mscx ("Repeat Text Left" /
  "Repeat Text Right"), not an invented name.
- A tie's `<Spanner type="Tie"><next|prev><location>` payload carries
  `<measures>` (present only when the tie crosses a barline) plus a
  `<fractions>` magnitude whose sign depends on BOTH which side (start
  vs stop) AND whether it's same-bar or cross-bar — see
  MSCXEncoder+Voice+Ties.swift's forwardTieLocation/backwardTieLocation
  and the `chord()` docstring below. Cross-checked against a real
  MuseScore-written cross-measure tie in Tests/SheetMusicTests/Resources/
  musicxml/testUnterminatedTies_ref.mscx:188-198,211-221.
- A common/cut time signature is a plain `<sigN>`/`<sigD>` `<TimeSig>`
  plus a leading `<subtype>` integer (MuseScore's `TimeSigType` enum
  ordinal: 1 = common/four-four "C", 2 = alla breve/cut "cut-C"),
  written before `<sigN>`/`<sigD>`. This element/ordering is not
  present anywhere in this repo's own Sources or fixtures (this
  package's model has no notion of the glyph-choice subtype at all) —
  confirmed instead directly against upstream MuseScore's own engraving
  source (`TWrite::write(const TimeSig*, ...)` in twrite.cpp writes
  `Pid::TIMESIG_TYPE` — XML name "subtype" — before sigN/sigD;
  `TRead::read(TimeSig*, ...)` in read400/tread.cpp reads it back the
  same way for `mscVersion() > 114`, and MS3's own read206.cpp delegates
  to that same read400 TimeSig reader, so this is shared by both native
  MS3 and MS4). Studied only, per CLAUDE.md — no MuseScore source is
  vendored here.
"""

from dataclasses import dataclass, field

import numpy as np


@dataclass
class PartSpec:
    name: str
    clef: str = "G"          # MuseScore defaultClef token
    measures: list[str] = field(default_factory=list)
    # Optional per-measure extra XML injected as a sibling of <voice>
    # inside <Measure> (index-aligned with `measures`; "" / missing = none).
    # Needed for elements MuseScore anchors at the Measure level rather
    # than inside the voice stream — currently Marker/Jump navigation
    # marks. See MSCXDecoder+Measure.swift.
    measure_siblings: list[str] = field(default_factory=list)


def _staff_block(clef: str) -> str:
    clef_el = f"\n        <defaultClef>{clef}</defaultClef>" if clef != "G" else ""
    return (
        '      <Staff id="{sid}">\n'
        '        <StaffType group="pitched">\n'
        "          <name>stdNormal</name>\n"
        "        </StaffType>" + clef_el + "\n"
        "      </Staff>"
    )


def mscx_document(parts: list[PartSpec], division: int = 480) -> str:
    """Minimal MuseScore-3.02 document. One staff per part."""
    part_blocks = []
    staff_blocks = []
    for i, part in enumerate(parts, start=1):
        part_blocks.append(
            "    <Part>\n"
            + _staff_block(part.clef).format(sid=i) + "\n"
            + f"      <trackName>{part.name}</trackName>\n"
            + "      <Instrument>\n"
            + f"        <longName>{part.name}</longName>\n"
            + f"        <trackName>{part.name}</trackName>\n"
            + '        <Channel>\n          <program value="0"/>\n        </Channel>\n'
            + "      </Instrument>\n"
            + "    </Part>"
        )
        measure_blocks = []
        for idx, m in enumerate(part.measures):
            sibling = (
                part.measure_siblings[idx]
                if idx < len(part.measure_siblings)
                else ""
            )
            sibling_block = f"{sibling}\n" if sibling else ""
            measure_blocks.append(
                f"      <Measure>\n{sibling_block}"
                f"        <voice>\n{m}\n        </voice>\n"
                "      </Measure>"
            )
        measures = "\n".join(measure_blocks)
        staff_blocks.append(f'    <Staff id="{i}">\n{measures}\n    </Staff>')
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
    # the default — omitted), 1 = FOUR_FOUR ("C" common-time glyph),
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
          tie_fraction: str = "1/4", tie_measures: int | None = None) -> str:
    # Element order mirrors MuseScore Studio's own writer: <dots> before
    # <durationType> (see module docstring — the reverse order makes
    # MuseScore's loader silently drop the dot).
    dots_el = f"            <dots>{dots}</dots>\n" if dots else ""
    acc_el = (
        f"\n              <Accidental>\n                <subtype>{accidental}"
        "</subtype>\n              </Accidental>"
        if accidental else ""
    )
    # <location> = <measures> (present only when the tie crosses a
    # barline) + a signed <fractions> magnitude. Caller supplies both
    # fully formed — see MSCXEncoder+Voice+Ties.swift's
    # forwardTieLocation/backwardTieLocation, which this mirrors:
    #   same-bar start:  fractions = +sourceDuration,           no <measures>
    #   cross-bar start: fractions = sourceDuration - barLength  (negative), <measures>1</measures>
    #   same-bar stop:   fractions = -prevChordDuration,        no <measures>
    #   cross-bar stop:  fractions = prevVoiceTotal - prevChordDuration (positive), <measures>-1</measures>
    # A single "-{tie_frac}" auto-negation (the earlier, buggy shape of
    # this helper) cannot express both same-bar and cross-bar stop signs
    # at once — the cross-bar case needs a positive fraction and the
    # same-bar case needs a negative one — so callers must pass the
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
        f"{dots_el}"
        f"            <durationType>{duration}</durationType>\n"
        "            <Note>\n"
        f"              <pitch>{pitch}</pitch>\n"
        f"              <tpc>{tpc}</tpc>{acc_el}{tie_el}\n"
        "            </Note>\n"
        "          </Chord>"
    )


def rest(duration: str = "quarter") -> str:
    return (
        "          <Rest>\n"
        f"            <durationType>{duration}</durationType>\n"
        "          </Rest>"
    )


def marker(label: str, sym: str) -> str:
    # Measure-level sibling of <voice> — see module docstring.
    return (
        "        <Marker>\n"
        "          <style>Repeat Text Left</style>\n"
        f"          <text><sym>{sym}</sym></text>\n"
        f"          <label>{label}</label>\n"
        "        </Marker>"
    )


def jump(text: str, jump_to: str, play_until: str) -> str:
    # Measure-level sibling of <voice> — see module docstring.
    return (
        "        <Jump>\n"
        "          <style>Repeat Text Right</style>\n"
        f"          <text>{text}</text>\n"
        f"          <jumpTo>{jump_to}</jumpTo>\n"
        f"          <playUntil>{play_until}</playUntil>\n"
        "          <continueAt></continueAt>\n"
        "        </Jump>"
    )


def fermata() -> str:
    return (
        "          <Fermata>\n"
        "            <subtype>fermataAbove</subtype>\n"
        "          </Fermata>"
    )


_CLEFS = ["G", "G8va", "G8vb", "G15ma", "G15mb",
          "F", "F8va", "F8vb", "F15ma", "F15mb", "C", "PERC"]


def coverage_sources(seed: int) -> list[tuple[str, str]]:
    """One source per coverage family. The rng only jitters pitches, so
    class coverage is structural, not sampled."""
    rng = np.random.default_rng(seed)
    sources: list[tuple[str, str]] = []

    # 1. Clef family — one file per clef, 8 bars of quarter notes.
    for clef in _CLEFS:
        base = 60 if clef.startswith("G") else 48 if clef.startswith("F") else 55
        measures = []
        for _ in range(8):
            pitches = base + rng.integers(-5, 6, size=4)
            body = [time_sig(4, 4)] if not measures else []
            body += [chord(int(p), 14) for p in pitches]
            measures.append("\n".join(body))
        sources.append((
            f"cov_clef_{clef.lower()}",
            mscx_document([PartSpec(name=f"Clef {clef}", clef=clef, measures=measures)]),
        ))

    # 2. Accidentals incl. doubles (MuseScore SMuFL-style subtype names).
    acc_measures = ["\n".join([
        time_sig(4, 4),
        chord(61, 21, accidental="accidentalSharp"),
        chord(62, 16, accidental="accidentalDoubleSharp"),
        chord(63, 9, accidental="accidentalFlat"),
        chord(62, 2, accidental="accidentalDoubleFlat"),
    ])] + ["\n".join([
        chord(60, 14, accidental="accidentalNatural"),
        chord(60, 14), chord(60, 14), chord(60, 14),
    ])]
    sources.append(("cov_accidentals",
                    mscx_document([PartSpec(name="Accidentals", measures=acc_measures)])))

    # 3. Durations: breve/whole down to 64th, plus dots and rests.
    dur_measures = [
        "\n".join([time_sig(4, 2), chord(60, 14, duration="breve")]),
        "\n".join([time_sig(4, 4), chord(60, 14, duration="whole")]),
        "\n".join([chord(60, 14, duration="half", dots=1),
                   chord(62, 16, duration="quarter")]),
        "\n".join([chord(60, 14, duration="quarter", dots=2),
                   chord(62, 16, duration="16th"), rest("quarter"), rest("quarter")]),
        "\n".join([chord(60, 14, duration="64th")] * 8
                  + [rest("64th")] * 8
                  + [chord(62, 16, duration="32nd")] * 4
                  + [rest("32nd")] * 4
                  + [rest("eighth"), rest("16th"), rest("16th"),
                     rest("quarter"), rest("half")]),
        "\n".join([rest("whole")]),
    ]
    sources.append(("cov_durations",
                    mscx_document([PartSpec(name="Durations", measures=dur_measures)])))

    # 4. Time signatures: digits 0-9 via changing meters (10/4 covers 0
    # and 1), plus common (subtype=1, "C") and cut (subtype=2, "cut-C")
    # time symbol glyphs (timeSigCommon / timeSigCutTime).
    ts_measures = []
    for n, d in [(2, 4), (3, 4), (5, 4), (6, 8), (7, 8), (9, 8), (10, 4), (12, 8)]:
        beats = n if d == 4 else max(2, n // 2)
        dur = "quarter" if d == 4 else "quarter"
        body = [time_sig(n, d)] + [chord(60, 14, duration=dur) for _ in range(beats)]
        ts_measures.append("\n".join(body))
    ts_measures.append("\n".join(
        [time_sig(4, 4, subtype=1)] + [chord(60, 14) for _ in range(4)]))
    ts_measures.append("\n".join(
        [time_sig(2, 2, subtype=2)] + [chord(60, 14, duration="half") for _ in range(2)]))
    sources.append(("cov_timesigs",
                    mscx_document([PartSpec(name="Meters", measures=ts_measures)])))

    # 5. Ties — chains across barlines and within measures.
    #
    # Measure A: two halves, second tied forward across the barline
    # (dur=2/4, barLength=4/4 -> fractions = 2/4-4/4 = -2/4, measures=1).
    # Measure B: first half receives that tie (prevTotal=4/4,
    # prevDur=2/4 -> fractions = 4/4-2/4 = +2/4, measures=-1), then two
    # quarters tied to each other within the same measure (start:
    # fractions=+1/4 no <measures>; stop: fractions=-1/4 no <measures>).
    tie_measures = []
    for _ in range(4):
        p = int(60 + rng.integers(-4, 5))
        tie_measures.append("\n".join(
            ([time_sig(4, 4)] if not tie_measures else [])
            + [chord(p, 14, duration="half"),
               chord(p, 14, duration="half", tie="start",
                     tie_fraction="-2/4", tie_measures=1)]))
        tie_measures.append("\n".join(
            [chord(p, 14, duration="half", tie="stop",
                   tie_fraction="2/4", tie_measures=-1),
             chord(p, 14, duration="quarter", tie="start", tie_fraction="1/4"),
             chord(p, 14, duration="quarter", tie="stop", tie_fraction="-1/4")]))
    sources.append(("cov_ties",
                    mscx_document([PartSpec(name="Ties", measures=tie_measures)])))

    # 6. Navigation: segno/coda markers + D.S./D.C. jumps + fermatas.
    # Marker/Jump are Measure-level siblings of <voice> (see module
    # docstring), so they travel in `measure_siblings`, index-aligned
    # with `measures`. Fermata stays inside the voice stream.
    nav_measures = [
        "\n".join([time_sig(4, 4)] + [chord(60, 14) for _ in range(4)]),
        "\n".join([chord(62, 16) for _ in range(4)]),
        "\n".join([fermata(), chord(64, 18, duration="whole")]),
        "\n".join([chord(60, 14) for _ in range(4)]),
        "\n".join([chord(60, 14) for _ in range(4)]),
    ]
    nav_siblings = [
        marker("segno", "segno"),
        # Not a typo: MuseScore's own file-string vocabulary is
        # confusingly crossed here — a plain CODA marker's <label> is
        # "codab" while the string "coda" itself is reserved for
        # TOCODA. See Marker.swift's Kind.defaultLabel doc comment
        # (Sources/SheetMusicCore/Score/Marker.swift) for the mapping
        # table this mirrors.
        marker("codab", "coda"),
        "",
        jump("D.S. al Coda", "segno", "tocoda"),
        jump("D.C. al Fine", "start", "fine"),
    ]
    sources.append(("cov_navigation",
                    mscx_document([PartSpec(name="Navigation", measures=nav_measures,
                                             measure_siblings=nav_siblings)])))

    return sorted(sources, key=lambda s: s[0])
