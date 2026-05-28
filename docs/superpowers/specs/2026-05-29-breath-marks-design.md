# Breath marks and caesuras — design

**Status:** approved 2026-05-29
**Scope:** MSCX round-trip + MusicXML round-trip + Layout (Apple + Android) + MIDI playback
**Modelled on:** `Fermata` (precedent for a SMuFL-named, MIDI-affecting, chord-adjacent score element)

## What this adds

Notation support for the eight SMuFL symbols MuseScore exposes under its
single `<Breath>` element:

| Kind                 | SMuFL name           | Codepoint |
| -------------------- | -------------------- | --------- |
| breath mark, comma   | `breathMarkComma`    | U+E4CE    |
| breath mark, tick    | `breathMarkTick`     | U+E4CF    |
| breath mark, upbow   | `breathMarkUpbow`    | U+E4D0    |
| breath mark, salzedo | `breathMarkSalzedo`  | U+E4D5    |
| caesura, normal      | `caesura`            | U+E4D1    |
| caesura, short       | `caesuraShort`       | U+E4D3    |
| caesura, thick       | `caesuraThick`       | U+E4D2    |
| caesura, curved      | `caesuraCurved`      | U+E4D4    |

The two families share an MSCX element but differ in semantics: breath
marks are visual articulations between two chords, caesuras additionally
insert a measured silence during playback. Both render as a single
SMuFL glyph sitting above the staff between two chords.

## Score model

New file `Sources/SheetMusicCore/Score/Breath.swift`:

```swift
/// A breath mark or caesura sitting between two chords in a voice.
/// C++: `mu::engraving::Breath`.
public struct Breath: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case breathMark(BreathMarkStyle)
        case caesura(CaesuraStyle)
    }

    public enum BreathMarkStyle: String, Sendable, Equatable, CaseIterable {
        case comma, tick, upbow, salzedo
    }

    public enum CaesuraStyle: String, Sendable, Equatable, CaseIterable {
        case normal, short, thick, curved
    }

    public var kind: Kind

    /// Seconds of silence inserted after the preceding chord during MIDI
    /// playback. Caesura defaults are non-zero (style-dependent); breath
    /// marks default to 0 (visual-only) — matching MuseScore 4 defaults.
    /// Mirrors MuseScore `<Breath><pause>`.
    public var pause: Double

    /// Base element properties shared with every engravable element.
    /// Currently carries only `<visible>`; see `ElementProperties`.
    public var elementProperties: ElementProperties
    /// Sugar over `elementProperties.visible`.
    public var visible: Bool { get set }

    public init(kind: Kind, pause: Double? = nil, visible: Bool = true)

    /// MuseScore 4 default pause (seconds) for a given kind.
    /// - breath marks: 0 (visual only)
    /// - caesura .normal: 0.5
    /// - caesura .short: 0.25
    /// - caesura .thick: 0.75
    /// - caesura .curved: 0.5
    public static func defaultPause(for kind: Kind) -> Double
}
```

`VoiceElement` gains one case:

```swift
case breath(Breath)
```

Position semantics: `.breath(...)` is an **independent voice element**
sitting *after* the chord it follows in `Voice.elements` — exactly the
same position MuseScore's segment graph puts `<Breath>` in. It is not
attached to a chord. This keeps voice-element handling uniform (no
chord-side mutation) and makes round-trip trivial: the MSCX segment
order maps 1:1 to Swift voice element order.

### Exhaustive switch obligation

Every existing exhaustive switch over `VoiceElement` must add a
`.breath(...)` arm. The implementation plan enumerates these explicitly
(per the memory note `feedback_swift_enum_case_addition_scope`). No
`default:` shortcuts.

## MSCX (round-trip)

- New decoder file `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Breath.swift`.
- New encoder file `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Breath.swift`.
- Dispatch wired from `MSCXDecoder+Voice.swift` and `MSCXEncoder+Voice.swift`.

### Element shape (MSCX 4)

```xml
<Breath>
  <subtype>breathMarkComma</subtype>   <!-- or one of the 8 SMuFL names above -->
  <pause>0</pause>                     <!-- seconds; optional -->
  <visible>0</visible>                 <!-- optional, ElementProperties default -->
</Breath>
```

### SMuFL name ↔ Kind mapping

The decoder/encoder share a single switch table:

| `<subtype>`         | `Breath.Kind`              |
| ------------------- | -------------------------- |
| `breathMarkComma`   | `.breathMark(.comma)`      |
| `breathMarkTick`    | `.breathMark(.tick)`       |
| `breathMarkUpbow`   | `.breathMark(.upbow)`      |
| `breathMarkSalzedo` | `.breathMark(.salzedo)`    |
| `caesura`           | `.caesura(.normal)`        |
| `caesuraShort`      | `.caesura(.short)`         |
| `caesuraThick`      | `.caesura(.thick)`         |
| `caesuraCurved`     | `.caesura(.curved)`        |

### Permissive parsing

- Unknown `<subtype>` → `.breathMark(.comma)` with `visible = true` (most
  conservative visual fallback). Logged through the existing
  `mscxDecoderLogger.warning(...)` pathway used elsewhere in the
  decoder.
- Missing `<pause>` → `Breath.defaultPause(for:)`.
- Unknown child elements inside `<Breath>` → skipped (existing voice
  parser convention).

### Encoder ordering

Emit children in the order MuseScore writes them: `<subtype>` first,
`<pause>` second (only when non-default to match MuseScore's "omit
defaults" behaviour observed in existing Fermata encoding), then any
`<visible>0</visible>` from `ElementProperties`.

## MusicXML (round-trip)

In MusicXML, breath marks and caesuras live inside `<notations>` of a
specific `<note>`:

```xml
<note>
  ...
  <notations>
    <breath-mark>comma</breath-mark>   <!-- comma | tick | upbow | salzedo -->
  </notations>
</note>
```

```xml
<note>
  ...
  <notations>
    <caesura>normal</caesura>          <!-- normal | short | thick | curved -->
  </notations>
</note>
```

### Decoder (`MusicXMLDecoder+Note.swift` + new `+Breath.swift`)

After the host note's chord is fully constructed and pushed into
`voice.elements`, the decoder appends `.breath(...)` immediately after.
This places it before the next chord, matching the visual semantics
("breath taken after this note").

Mapping:

- `<breath-mark>` text value `comma`/`tick`/`upbow`/`salzedo` → matching
  `BreathMarkStyle`. Empty content or unknown value → `.comma`.
- `<caesura>` text value `normal`/`short`/`thick`/`curved` → matching
  `CaesuraStyle`. Empty content (MusicXML 3.x didn't have a value) →
  `.normal`. Unknown value → `.normal`.

`pause` is **not** carried in MusicXML, so the decoder uses
`Breath.defaultPause(for:)`.

### Encoder

`SheetMusicMusicXML` is import-only as of this writing (no `Encoders/`
directory). Round-trip on the MusicXML side therefore means
`MusicXML → Score`; no encoder work is in scope here. When MusicXML
export is added in a future phase, breath emission follows the inverse
of the decoder: locate the chord preceding the `.breath(...)` voice
element and write `<breath-mark>` / `<caesura>` into its `<notations>`.

## MIDI render

In `Sources/SheetMusicMIDI/Render/MidiRenderer+Voice.swift`, when the
voice walker encounters `.breath(b)`:

- If `b.pause == 0`, do nothing. The next chord's onset is unchanged.
- If `b.pause > 0`, advance the local tick cursor by
  `ticks = round(b.pause * (currentBPM / 60) * ppq)`, where
  `currentBPM` is the active tempo at the breath's position. This makes
  the next chord start `b.pause` real-time seconds later than it would
  otherwise.

The preceding chord's note-off events stay at their natural release
(MuseScore does not shorten the chord; it inserts dead time). This
matches MuseScore 4's `Breath::play()` behaviour.

Tempo changes that fall *exactly* on a breath are resolved by reading
the tempo map at the breath's tick (i.e. the tempo *active going into*
the silence). A tempo change that occurs *during* a multi-second
caesura silence is ignored — MuseScore behaves the same.

## Layout

### Element + emission

- `LayoutElement` gains `.breath(BreathPlacement)` where
  `BreathPlacement` carries the resolved SMuFL codepoint, the staff it
  attaches to, and the engraving position.
- `LayoutEngine+Translate.swift` converts `VoiceElement.breath` to
  `LayoutElement.breath` during voice flattening.
- `LayoutEngine+Emit.swift` emits the glyph at:
  - **X**: midpoint between the right edge of the preceding chord's
    rightmost notehead column and the left edge of the next chord's
    leftmost element, *minus* a left-bias shift so the glyph hangs
    just before the next chord (MuseScore's `breathMarkPos = -1.5sp`
    horizontal offset from next segment's left).
  - **Y**: anchored to the top staff line. Breath marks sit on top of
    the staff (y = top line - 1.0 sp). Caesuras sit slightly higher
    (y = top line - 2.0 sp). Y per-style fine-tuning lives in
    `BreathGlyphMetrics`.

### Horizontal spacing

`LayoutEngine+Spacing.swift` reserves horizontal room for the breath:

- ~1.0 spatium gap *before* the next chord, where the glyph sits.
- ~0.5 spatium right-padding so the next chord's accidental/notehead
  does not touch the glyph.

These constants are derived from MuseScore's `styleDefaults` for
`breathMarkPad` / `breathRightSpacing`; exact spatium values are
finalised during implementation against rendered-snapshot tests.

### New files

- `Sources/SheetMusicLayout/Engraving/BreathGlyph.swift` — kind →
  SMuFL codepoint + default Y offset.
- `Sources/SheetMusicLayout/Fonts/BreathGlyphMetrics.swift` — ascender
  / advance lookup via the existing `FontMetricsProvider`, mirroring
  `FermataGlyphMetrics`.
- Codepoints listed in `Sources/SheetMusicLayout/Engraving/SMuFLCodepoints.swift`.

### Visibility

`Breath.visible == false` skips emission entirely. When the global
`ScoreViewOptions.showsInvisibleElements` flag is on (see
`ElementProperties` / `showsInvisibleElements` work merged in f3d9cf8),
the glyph is emitted at half opacity through the existing invisible-
element pathway — no new flag is needed.

## Android (JNI bridge)

In `Sources/SheetMusicAndroidJNI/LayoutBridge+Engraving.swift`, add a
`LayoutElement.breath` → `DrawCommand.glyph` conversion. The codepoints
live in the existing Bravura SMuFL font already shipped to Android, so
no new `FontID` is needed and no Kotlin-side renderer change is
required. Wire-format version stays at v4.

## Audio

`SheetMusicAudio*` renders to MIDI first and then plays the MIDI, so
the playback engine inherits caesura silence automatically through the
MIDI renderer change. No `SheetMusicAudioApple` /
`SheetMusicAudioAndroid` change is needed for v0.

## Tests

### Fixtures

Add to `Tests/SheetMusicTests/Resources/`:

- `breath_marks.mscx` — one staff, four bars, each bar exercises a
  different `BreathMarkStyle`. Created in MuseScore 4 with default
  style settings, then committed under the GPL-3.0 license already
  declared for the directory.
- `caesuras.mscx` — same shape for `CaesuraStyle`.
- `breath_marks-ref.mid` and `caesuras-ref.mid` — MuseScore 4's own
  MIDI export of those fixtures, for the semantic-equivalence test
  harness.

### Coverage

- **MSCX round-trip:** parse each fixture, encode it back, parse again,
  assert structural equality. Two cases.
- **MusicXML import:** hand-author small `<note>`-with-`<breath-mark>`
  and `<note>`-with-`<caesura>` fragments, parse, assert exactly one
  `.breath(...)` voice element with the expected kind/pause.
- **MIDI semantic equivalence:** feed each fixture through the existing
  `MidiSemanticComparison` helper against its `-ref.mid`. Tolerance
  inherits from current `MidiExportTests` config.
- **Layout snapshot:** add a `#Preview` block in `RenderPreviews/main.swift`
  for the breath-marks fixture and render it once during the
  implementation phase; the rendered PNG is checked into the worktree's
  scratch dir for human review (not committed).

## Out of scope

- An `EditCommand` to insert/remove a breath mark from a chord at a
  given measure position. Defer to a follow-up phase that also covers
  fermata insertion.
- MuseScore 5 / custom SMuFL extensions beyond the eight subtypes
  above. Unknown subtypes fall back to `.comma`.
- Per-voice or per-staff alignment of simultaneous breaths across
  multiple voices/staves. v0 emits each one independently.
- Audio-engine-level pause realisation (e.g. crossfading the next
  chord's velocity into the silence). MIDI tick advancement is
  sufficient for both Apple `AVAudioSequencer` and Android FluidSynth.
- A dedicated Android `FontID` for breath glyphs. The existing Bravura
  font carries them.

## Implementation order

A `writing-plans` plan will follow this spec and split the work into:

1. Score model + `VoiceElement.breath` + every exhaustive-switch update.
2. MSCX decoder/encoder + round-trip test.
3. MusicXML decoder + import test.
4. MIDI renderer + semantic-equivalence test against MuseScore export.
5. Layout (Apple) + RenderPreviews snapshot.
6. Android JNI bridge + Compose example verification.

Each step is independently green-testable, in line with the project's
incremental landing pattern (`feature/breath-marks` branch, one commit
per step).
