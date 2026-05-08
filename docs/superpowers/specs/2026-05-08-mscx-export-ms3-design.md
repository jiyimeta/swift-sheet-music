# MSCX Export — MuseScore 3 Target (`MSCXVersion.v3` option)

Status: design
Date: 2026-05-08
Branch: `feature/mscx-export` (continues — no new branch)
Predecessor specs:
- `docs/superpowers/specs/2026-05-07-mscx-export-design.md` (Phase 1+2)
- `docs/superpowers/specs/2026-05-08-mscx-export-phase3-polish-design.md` (skip-if-default Style + spanner fractions)
Related (read side, not a prerequisite):
- `docs/superpowers/specs/2026-04-15-musescore-3-mscx-support.md` (MS3 reading, `Status: proposed`)

## Background

`feature/mscx-export` ships an `MSCXEncoder` that produces MuseScore-4
flavoured `.mscx` (`<museScore version="4.60">`). Phase 3 made
MIDI-imported scores openable in MuseScore Studio (= MS4). Users with
MuseScore 3.6.2 cannot open the same files because the wire form has
diverged in several places.

This spec adds an output-format option so callers can request MS3
flavoured `.mscx` / `.mscz`. The reader side (parsing MS3 input) is a
separate spec and is **not** a prerequisite — the encoder targets MS3
purely as a write-time transformation.

## Goals

- A MIDI-imported `Score` (the subset Phase 3 covers) round-trips
  through `MSCXEncoder.encode(_:options:)` with `targetVersion = .v3`
  and opens cleanly in MuseScore 3.6.2.
- Existing callers (`SheetMusic.exportMSCX(score)` /
  `exportMSCZ(score)` / `MSCXEncoder.encode(score)`) keep their MS4
  default behaviour with zero source-level changes.
- All wire-form differences derived from the canonical MS3 reference at
  `~/Desktop/test-min.mscx` (a hand-built minimal score saved by
  MS3.6.2) are encoded into the v3 branch.

## Non-goals

- Reading MS3 `.mscx` (separate spec).
- Round-tripping MuseScore-4-parsed scores through v3 export — only
  the MIDI-import subset is in scope. MS4-only constructs that the
  decoder might surface (MS4-specific articulations, page-layout
  fields beyond what MS3 understands, MS4 chord-symbol attributes)
  are best-effort: emit if it costs nothing, drop or ignore otherwise.
  No attempt at full MS4 → MS3 lowering.
- MS3 `.mscz` internal layout (`META-INF/container.xml`, thumbnails).
  MS3.6.2's reader resolves the main `.mscx` by entry name, so the
  current minimal `MSCZWriter` archive (single entry) is accepted.
- Example app UI for MS3 export.
- MuseScore 1.x / 2.x output.
- MuseScore 5.x output. Future enum case (`.v5`) and its branches are
  deferred.

## Reference artefact

`~/Desktop/test-min.mscx` (NOT checked in to the repo per the user's
request — license / scope hygiene). Hand-built minimal MS3 sample
re-saved by MuseScore 3.6.2, exercising:

- Multi-staff Part (Piano grand-staff: treble + bass + curly bracket)
- Drumset Part (5-line percussion StaffType, multi-voice: voice 0
  snare/hi-hat with stems up + voice 1 kick with stems down)
- KeySig change mid-piece (M2: accidental=0 → accidental=2)
- TimeSig change mid-piece (M2: 4/4 → 3/4)
- Tuplet (triplet of eighths) + dotted duration + cross-measure tie
- Tempo, measure rest, dotted half across odd time

The "canonical" form is what MS3.6.2 emitted after re-saving — that is
the byte sequence the encoder targets.

## Architecture

### Type additions

`SheetMusicCore`:

```swift
public enum MSCXVersion: Sendable, Hashable {
    case v3   // MuseScore 3.x  → version="3.02", programVersion="3.6.2"
    case v4   // MuseScore 4.x  → version="4.60"
}
```

`SheetMusicMSCX`:

```swift
public struct MSCXEncoderOptions: Sendable {
    public var targetVersion: MSCXVersion
    public init(targetVersion: MSCXVersion = .v4) {
        self.targetVersion = targetVersion
    }
}
```

The reader-side spec also defines `MSCXVersion`; the same type is
shared so a future read implementation can use it for diagnostics
without duplicate enums.

### Public API

```swift
extension MSCXEncoder {
    // existing: public static func encode(_ score: Score) throws -> Data
    public static func encode(
        _ score: Score, options: MSCXEncoderOptions
    ) throws -> Data
}

extension MSCZWriter {
    public static func write(
        score: Score, options: MSCXEncoderOptions,
        mainFileName: String = "score.mscx"
    ) throws -> Data
    public static func write(
        score: Score, options: MSCXEncoderOptions, to: URL,
        mainFileName: String = "score.mscx"
    ) throws
}

extension SheetMusic {
    public static func exportMSCX(
        _ score: Score, options: MSCXEncoderOptions = .init()
    ) throws -> Data
    public static func exportMSCZ(
        _ score: Score, options: MSCXEncoderOptions = .init()
    ) throws -> Data
}
```

The existing zero-arg `encode(_ score:)` is kept (forwards to
`encode(_:options: .init())`) so all current call sites compile
unchanged.

### Internal plumbing

Each `MSCXEncoder+<Type>.swift` extension that needs a v3 branch
takes `options` via the encode entry point. Two paths:

1. **Top-level encoder**: `MSCXEncoder.encode(_:options:)` threads
   `options` through the score-building call graph.
2. **Per-type extensions**: receive `options` as a parameter on the
   relevant `encode(...)` helper. The signature change is additive — a
   defaulted `options:` parameter so existing call sites in tests
   continue to compile.

The choice between "thread `options` everywhere" vs "stash on a
per-encode context object" is left to the implementation plan. The
plumbing is mechanical either way.

## Wire-form differences (the v3 branches)

All differences below are derived from `~/Desktop/test-min.mscx` after
MS3.6.2 round-tripped it. Each section names the file the change
lives in.

### §A. Root / Score header — `MSCXEncoder+Score.swift`

- `<museScore version>` attribute: `"3.02"` (MS4 emits `"4.60"`).
- v3 only: emit `<programVersion>3.6.2</programVersion>` and
  `<programRevision>3224f34</programRevision>` directly under
  `<museScore>`, before `<Score>`.
- v3 only: inside `<Score>`, before `<Division>`, emit
  `<LayerTag id="0" tag="default"></LayerTag>` and
  `<currentLayer>0</currentLayer>`.
- v3 only: after `<Style>`, before metaTags, emit:
  `<showInvisible>1</showInvisible>` `<showUnprintable>1</showUnprintable>`
  `<showFrames>1</showFrames>` `<showMargins>0</showMargins>`.
- v3 only: emit metaTags as the canonical 13-element fixed set in
  this exact order, with empty text when absent:
  `arranger`, `composer`, `copyright`, `creationDate`,
  `lyricist`, `movementNumber`, `movementTitle`, `platform`,
  `poet`, `source`, `translator`, `workNumber`, `workTitle`.
  - `creationDate` ← `score.metaTags["creationDate"]` if non-empty,
    else today's date as `yyyy-MM-dd` (UTC).
  - `platform` ← `score.metaTags["platform"]` if non-empty, else
    `"Apple Macintosh"` (canonical default).
  - The other 11 take `score.metaTags[name]` (empty if missing).

### §B. Style — `MSCXEncoder+Style.swift`

- v3 emits `<Spatium>` (capital S) instead of `<spatium>`.
- v3 emits **only** the `<Spatium>` child. All other Phase 2.5 / 3
  fields (page geometry, header, footer, page-number) are skipped
  unconditionally for v3, even when the value differs from default.
  This matches MS3.6.2's canonical "minimal" Style block; MS3 picks up
  page geometry from its own internal defaults when reading.

### §C. KeySig — `MSCXEncoder+KeySignature.swift`

- A KeySig with `accidental == 0` placed at the very start of a staff
  body (no preceding KeySig change) is **omitted** for both v3 and
  v4. MS3 does not emit it (canonical evidence) and MS4 tolerates the
  omission. This is a shared change, not v3-specific.
- Mid-piece KeySig changes (any `accidental` value, after the first
  Measure that has its own KeySig) emit unchanged in both versions.
- "Very start" detection: if a Voice's first VoiceElement is a
  `.keySig` whose `accidental == 0` and this Voice is the first
  voice of the first Measure of the staff, drop it.

### §D. TimeSig — `MSCXEncoder+TimeSignature.swift`

No v3 branch. MS4 encoder already emits `<sigN>` / `<sigD>` (verified
in `MSCXEncoder+TimeSignature.swift:10-11`). MS3 expects the same
form.

### §E. Spanner location order — `MSCXEncoder+Spanner.swift`

- Inside `<next>...<location>` (and `<prev>...<location>`):
  - v4 emits `<fractions>` then `<measures>` (Phase 3 polish order,
    matches MuseScore 4's `engraving/types/location.cpp`).
  - v3 emits `<measures>` then `<fractions>` (canonical evidence).
  - Both keep "skip if default" semantics from Phase 3:
    `<fractions>` skipped when `nextFractionsOffset == nil`;
    `<measures>` skipped when `nextMeasuresOffset == 0`.
- All other spanner shapes (Tie/Slur/HairPin/Volta/Pedal/Ottava
  payload children, `<endings>`, `<visible>` handling) are identical
  in v3 and v4.

### §F. Channel — `MSCXEncoder+InstrumentChannel.swift`

- v3 only: when `<midiPort>` and/or `<midiChannel>` equal their
  defaults (`midiPort == 0`, `midiChannel == nil` or 0 for the first
  channel of the first part), suppress those children. Canonical MS3
  output omits both for the default Piano channel.
- v3 only: emit `<controller ctrl="32" value="0"/>` (Bank LSB) right
  after `<controller ctrl="0" value="X"/>` (Bank MSB) when the existing
  Phase 1 emission already includes the Bank MSB controller. MS3
  canonical writes both bank-select bytes.
- Other Channel children (`<program>`, `<synti>`, additional
  `<controller>` entries from `InstrumentChannel.controllers`) emit
  identically for both versions.

### §G. Drum chord stem direction & note head — `MSCXEncoder+Chord.swift`, `MSCXEncoder+Note.swift`

When the encoded chord lives on a percussion staff (`StaffType.group ==
"percussion"`) AND the target is v3:

- `MSCXEncoder+Chord.swift`: emit `<StemDirection>up</StemDirection>`
  (for voice index 0, MuseScore's stem-up voice) or `<StemDirection>down</StemDirection>`
  (for voice index 1+) as the first child of `<Chord>`, before
  `<durationType>`.
- `MSCXEncoder+Note.swift`: emit `<head>cross</head>` (or whatever
  `<head>` value the score's drumset definition specifies for that
  pitch) on the `<Note>` element. The drum head value is looked up
  from the part's `Drumset` definition.

If the `Drumset` definition is missing (hand-built Score with no
drumset table), default to `<head>normal</head>` and stem direction
based on voice index. MIDI import populates a drumset table for
percussion parts, so this should always succeed for the in-scope
input.

### §H. Untouched

These are identical in v3 and v4 wire form (canonical evidence):
- `<Part>` declarations: `<Staff>` children, `<bracket>`,
  `<barLineSpan>`, `<defaultClef>`, `<StaffType>`.
- `<Instrument>`: `longName`, `shortName`, `trackName`,
  `minPitchP/A`, `maxPitchP/A`, `instrumentId`.
- `<Drum>` definitions inside Instrument (head/line/voice/name/stem).
- `<useDrumset>1</useDrumset>` flag.
- `<Tempo>` (`<tempo>`, `<followText>`, `<text>` shape).
- `<Chord>` body (durationType, dots, Note children).
- `<Note>`: pitch, tpc.
- `<Rest>`: durationType, optional `<duration>` for measure rests.
- `<Tuplet>` (normalNotes/actualNotes/baseNote/`<Number>`) +
  `<endTuplet/>` placeholder.
- `formatDouble` precision policy (`String(Double)` for round-trip).

## Error handling

- No new error cases. `SheetMusicError.malformedScore` covers the
  same scenarios as before; `MSCXEncoderOptions` validation is
  unnecessary because `targetVersion` is an enum.
- `Voice.encode` and the rest of the exhaustive switches stay
  identical for v3 and v4. MS4-only VoiceElement variants don't get
  a "fail in v3" path — they encode whatever they encode and MS3 may
  silently drop the unknown element when reading. MIDI import does
  not produce such variants in the in-scope subset.

## Testing

### Unit tests (`Tests/SheetMusicTests/MSCXEncoderMS3Tests.swift`)

Wire-form-only tests, no MS3 binary required. Use the
`MidiImporter` output for `Tests/SheetMusicTests/Resources/midi01.mid`
or the existing parsed `midi01` Score as input.

1. `rootHeaderEmitsMS3Form` — encode with `.v3`, parse the bytes,
   assert `<museScore version="3.02">`, `<programVersion>3.6.2</programVersion>`,
   `<programRevision>3224f34</programRevision>`,
   `<LayerTag>` + `<currentLayer>` exist before `<Division>`,
   `<showInvisible>` ... `<showMargins>` exist after `<Style>`.
2. `metaTagsEmitsCanonicalThirteen` — assert exactly 13 `<metaTag>`
   children in the canonical order with the documented platform /
   creationDate fallbacks.
3. `styleEmitsOnlySpatiumCapitalS` — `<Style>` has exactly one child
   named `Spatium` (capital), value matches `String(Double)` of
   `score.style.spatium`.
4. `initialKeySigZeroOmitted` — first measure of each staff has no
   `<KeySig>` child for both v3 and v4 paths.
5. `midKeySigChangeEmitted` — second measure with `accidental == 2`
   does emit `<KeySig><accidental>2</accidental></KeySig>`.
6. `spannerLocationOrderV3` — encode a tied note that crosses a
   measure with both fractions and measures offsets (using
   Phase 3 `Spanner.nextFractionsOffset`); v3 emits
   `<measures>` before `<fractions>`, v4 emits the reverse.
7. `channelOmitsDefaultMidiPortChannelInV3` — v3 channel for the
   default piano channel drops `<midiPort>` and `<midiChannel>`;
   v4 keeps them.
8. `drumChordEmitsStemDirectionAndHeadInV3` — drumset score, v3 path,
   chord has `<StemDirection>` and note has `<head>` matching the
   drumset definition; v4 path does neither.
9. `existingMS4PathUnchanged` — reuse one existing Phase 3 round-trip
   assertion (e.g. midi01) explicitly through `options: .init()` to
   guard against regression. (Belt-and-suspenders: the existing 716+
   tests all run unchanged because `options` is defaulted.)
10. `midi01CanonicalKeyFieldsMatch` — encode the parsed midi01 score
    with `.v3`, reparse, assert the root attributes and Style children
    match `~/Desktop/test-min.mscx`'s canonical fields. Avoids
    importing the desktop file as a fixture; assertion targets the
    exact 4-5 canonical-form fields already documented in §A and §B.

### MS4-path regression

`swift test` must keep `MSCXRoundTripTests`, `MSCXEncoderStyleTests`,
`MSCXEncoderSpannersTests`, `MSCXEncoderSpannerFractionsTests`,
`MSCXEncoderStyleCompactnessTests`, `MSCXEncoderTextElementsTests`,
`MSCXEncoderScoreFrameTests` etc. all green (716+ tests).

### Manual acceptance (not in CI)

Before merging:

1. Take any small MIDI file (not a fixture).
2. `MidiImporter.import(...)` to a `Score`.
3. `SheetMusic.exportMSCZ(score, options: .init(targetVersion: .v3))`
   to a temp `.mscz`.
4. Open the file in MuseScore 3.6.2.
5. Verify visible structure: number of staves correct, KeySig and
   TimeSig as expected, Tuplet renders with bracket and number,
   Tie connects across measures, drumset stems differ between voices
   if present.

If any of the above fail, debug and patch the v3 branch in the
relevant `MSCXEncoder+*.swift` file. The canonical reference
`~/Desktop/test-min.mscx` is the ground truth; diff against the
encoder output to find the missing element.

## Files

**Created:**
- `Sources/SheetMusicCore/MSCXVersion.swift`
- `Sources/SheetMusicMSCX/MSCXEncoderOptions.swift`
- `Tests/SheetMusicTests/MSCXEncoderMS3Tests.swift`

**Modified:**
- `Sources/SheetMusicMSCX/MSCXEncoder.swift` (add `encode(_:options:)`)
- `Sources/SheetMusicMSCX/MSCZWriter.swift` (add options overloads)
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Score.swift` (§A)
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Style.swift` (§B)
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+KeySignature.swift` (§C)
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Spanner.swift` (§E)
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+InstrumentChannel.swift` (§F)
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Chord.swift` (§G stem)
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Note.swift` (§G head)
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Voice.swift` (thread `options`)
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Measure.swift` (thread `options`)
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Part.swift` (thread `options`)
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Staff.swift` (thread `options`)
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Instrument.swift` (thread `options`)
- `Sources/SheetMusic/SheetMusic.swift` (façade options overloads)
- `README.md` (one-line note about `MSCXEncoderOptions`)

**Untouched (no changes intended):**
- `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+TimeSignature.swift`
  (already emits `<sigN>` / `<sigD>`)
- All decoder files.
- All other encoder extensions (`+Tempo`, `+Note` for non-drum,
  `+NoteDuration`, `+BarLine`, `+Dynamic`, `+StaffText`,
  `+RehearsalMark`, `+Harmony`, `+MeasureRepeat`, `+Fermata`,
  `+InstrumentArticulation`, `+Clef`, `+ScoreFrame`,
  `+TextProperties`).

## Definition of Done

- All new types and APIs land as described in *Architecture*.
- Each wire-form difference in §A–§G is implemented in its named
  file, gated on `options.targetVersion == .v3`.
- 10 new tests in `MSCXEncoderMS3Tests.swift` pass.
- Existing 716+ tests pass.
- `swiftlint --quiet Sources Tests` reports 0 warnings/errors.
- Manual acceptance on MS3.6.2 succeeds for at least one
  MIDI-imported score. The reviewer (user) confirms the file opens.
- Branch `feature/mscx-export` carries the new commits; no new
  branch created.
- README mentions the options API in one line.

## Follow-ups (out of scope, separate PRs)

1. Drumset population from MIDI import (so §G actually fires for
   MIDI-imported drum tracks). Track in a separate spec when there's
   a concrete consumer.
2. Mac example: add an MS3 export button alongside the existing MS4
   export.
3. Future MS5 (or later) target — extend `MSCXVersion` with a new
   case and per-section branches as the wire form diverges.
