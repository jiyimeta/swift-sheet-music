# Anacrusis (pickup measure) support

Status: design • Date: 2026-05-08

## Problem

MuseScore lets a measure declare an actual length shorter (or longer)
than the prevailing time signature, and lets it opt out of automatic
measure numbering. The two attributes typically appear together on a
pickup measure (anacrusis / 弱起):

```xml
<Measure len="1/4">
  <irregular>1</irregular>
  <voice> … </voice>
</Measure>
```

`swift-sheet-music` currently ignores both: the parser does not read
the `len` attribute or the `<irregular>` element, and the `Measure`
type has no fields for them. As a result:

- MSCX round-trip silently strips both pieces of information.
- Layout numbers the anacrusis as measure 1 instead of skipping it,
  which contradicts engraving convention and the MuseScore display.
- MIDI playback happens to work because `MidiRenderer.measureTicks`
  derives length from the sum of voice contents — but the model has
  no ground-truth length to verify against.

## Goals

Vertical-slice support across Core, MSCX, and Layout, matching the
pattern of the recent `feature/swing` work:

1. Represent both attributes in the `Measure` model.
2. Round-trip them faithfully through the MSCX decoder and encoder.
3. Skip irregular measures in displayed measure numbers (sticky
   header + per-system head label).

MIDI rendering needs no behavioural change: existing content-driven
tick math already produces correct playback for well-formed files
written by MuseScore Studio.

## Non-goals

- Per-staff `len` divergence (advanced multi-meter use). Single
  measure-level `len` is assumed; if a future fixture surfaces a
  per-staff variant, design it then.
- MuseScore's measure-number offset feature (`noOffset`, custom
  starting number, every-N labelling). Out of scope; would compose
  with this work but is independent.
- Layout width adjustment proportional to `actualLength`. The
  existing content-driven width already produces a narrower bar for
  short anacruses; revisit only if a regression surfaces.
- New MSCX fixtures for `MidiExportTests` semantic-equivalence
  coverage. None of the upstream MuseScore midiexport fixtures
  exercise an anacrusis, and we intentionally don't author new
  GPL-derived fixtures of our own.

## Design

### Core: `Measure` gains two fields

```swift
public struct Measure: Sendable, Equatable {
    // existing: voices, startRepeat, endRepeatCount, measureRepeatCount,
    // markers, jumps, lineBreak, pageBreak

    /// `<Measure len="N/D">` — actual measure length when it differs
    /// from the prevailing time signature. `nil` means "follow the
    /// time signature". Mirrors `Measure::ticks()` vs `nominalTicks()`
    /// in MuseScore.
    public var actualLength: Fraction?

    /// `<irregular>1</irregular>` — exclude this measure from the
    /// running displayed number. Typically set on an anacrusis.
    public var irregular: Bool
}
```

Both fields default to `nil` / `false`, so existing call-sites that
construct `Measure` literals keep compiling. The memberwise initializer
gains the two parameters at the tail of the existing argument list.

`actualLength` and `irregular` are kept as independent fields rather
than fused into a single "is anacrusis" flag because MuseScore allows
each independently — for example, a short measure mid-piece (length
change without renumbering) or a renumber-only suppression.

### MSCX layer

`MSCXDecoder+Measure.decode(_:)`:

- Read `node.attributes["len"]`; when present, parse as `"N/D"` into
  `Fraction`. Malformed values (missing `/`, non-integer parts) fall
  back to `nil` rather than throwing — consistent with the parser's
  permissive posture for unknown / unparseable optional metadata.
- Read `node.first("irregular")`; treat text `"1"` as `true`,
  everything else as `false`.

`MSCXEncoder+Measure.encode(...)`:

- When `actualLength != nil`, emit it as the `len` attribute on the
  `<Measure>` root node, formatted `"\(numerator)/\(denominator)"`.
- When `irregular == true`, emit `<irregular>1</irregular>` near the
  head of the children (after `<startRepeat/>` / markers, before the
  voices), matching MuseScore Studio writer ordering.

### MIDI layer

No code change. `MidiRenderer.measureTicks` continues to derive ticks
from the voice contents. `actualLength` is intentionally not consulted
during render — using two sources of truth for measure length would
invite drift, and the contents-as-truth approach already passes all
12 `MidiExportTests` semantic-equivalence cases.

### Layout layer: numbering helper

Add `Sources/SheetMusicCore/Score/Score+MeasureNumber.swift`:

```swift
extension Score {
    /// 1-based displayed measure number, with `irregular` measures
    /// excluded from the running count. Returns `nil` for an
    /// irregular measure (no label drawn).
    ///
    /// Uses staff 0 as the source of truth for `irregular`. Per-staff
    /// divergence is out of scope.
    public func displayedMeasureNumber(at index: Int) -> Int?
}
```

Implementation walks `allStaves[0].measures[0..<=index]`; if
`measures[index].irregular` is true, return `nil`; otherwise return
`(count of non-irregular measures in 0...index)`.

Two layout call-sites consume the helper:

1. `LayoutEngine+Contexts.swift` — sticky-header `#N` label.
   Currently `"#\(context.measureIndex + 1)"`. Becomes:
   `score.displayedMeasureNumber(at: context.measureIndex).map { "#\($0)" }`.
   Suppress the marker emission when the helper returns `nil`.

2. `LayoutEngine+SystemBuild.swift` — per-system head label.
   Currently `"\(measureIdx + 1)"`. Becomes the same helper call;
   suppress emission on `nil`.

The `Score` reference is already in scope at both sites
(`LayoutEngine` carries it through context construction), so no new
plumbing is needed.

### Tests

Add `Tests/SheetMusicTests/AnacrusisTests.swift` with three cases
using Swift Testing (`@Test`, `#expect`):

1. **MSCX round-trip (encoder + decoder)** — construct a `Score` with
   one staff containing an irregular pickup measure
   (`actualLength == 1/4`, `irregular == true`), encode via
   `MSCXEncoder`, parse the resulting bytes via `MSCXParser`, and
   `#expect` the decoded `Measure` equals the source. Equatable
   conformance covers both new fields.

2. **Decoder XML tolerance** — feed a hand-written minimal `<Score>`
   string with `<Measure len="1/4"><irregular>1</irregular> …` to
   `MSCXParser`, `#expect` `actualLength == Fraction(1, 4)` and
   `irregular == true` on the decoded measure.

3. **Layout numbering** — build a 3-measure `Score` where measure 0
   is `irregular`, run `LayoutEngine`, scan the resulting
   `LayoutMeasure.markers` for `.measureNumber`, and `#expect`:
   - measure 0 emits no `.measureNumber` element,
   - measure 1's label is `"1"`,
   - measure 2's label is `"2"`.
   Same assertion pattern applies to the sticky header label
   (prefixed with `#`).

The unit covering `Score.displayedMeasureNumber` is exercised
transitively by case 3; a dedicated micro-test is unnecessary.

## Risks / open questions

- **Encoder ordering**: MuseScore Studio's writer places
  `<irregular>` early in the measure children. The exact slot doesn't
  affect semantic round-trip (the decoder is order-tolerant), but
  matching writer order keeps fixture diffs readable. Final position
  is decided at implementation time after a quick look at a
  MuseScore-Studio-written fixture; if no fixture exists in this
  repo, fall back to "after `<startRepeat/>`, before the first
  `<voice>`".
- **Existing fixtures regression**: none of the 12 `MidiExportTests`
  fixtures contain `len` or `<irregular>`, so adding the fields is
  additive and the existing semantic-equivalence corpus is unaffected.
  CI should still be 100% green post-change.
