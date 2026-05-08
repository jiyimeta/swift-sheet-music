# MSCX Export — Phase 3 Polish (skip-if-default Style + spanner `<fractions>`)

Status: design
Date: 2026-05-08
Branch: `feature/mscx-export` (continues — no new branch)
Predecessor specs:
- `docs/superpowers/specs/2026-05-07-mscx-export-design.md`

## Background

`feature/mscx-export` (37 commits ahead of `main` as of 2026-05-08) has
shipped Phase 1 + Phase 2.1–2.5: every `Voice.encode` case is covered,
`<VBox>` title block + full `<Style>` page-layout/chrome encoding round-
trip, and 710/710 tests pass.

Three polish items were noted in the original Phase 2 follow-up memory:

1. **Hand-built `Score` → MuseScore-Studio-openable output.** Requires
   default fill-in for fields the parser populates with defaults
   (channel CCs, instrument templates, eid generation, default
   `<Style>`).
2. **"Skip if equal to default" `<Style>` emission**, so parse → encode
   output stays close to MuseScore Studio's own terse `<Style>` block.
3. **Accurate `<measures>` / `<fractions>` on cross-measure spanners.**

This spec covers (2) and (3) only. Item (1) is deferred to a separate
spec when a concrete consumer drives the "what *is* a sensible default
Score?" design question.

## Goals (this spec)

- Parse → encode → reparse on already-parsed scores produces an
  XML tree whose `<Style>` block is significantly more compact than
  today's "emit everything" output, while preserving full
  `ScoreStyle` equality through round-trip.
- Cross-measure spanners that include a `<fractions>` element in their
  `<next><location>` survive parse → encode round-trip (currently
  silently dropped).

## Non-goals (this spec)

- Hand-built `Score` defaults / MuseScore Studio compatibility for
  scores that were never parsed (Phase 3 (a)).
- Computing spanner end positions from absolute end-ticks. The
  spanner span representation stays "relative offset preserved from
  input"; absolute-tick computation belongs to Phase 3 (a).
- Touching any non-`<Style>` block for compactness (e.g. `<Part>`,
  `<Measure>`, `<Score>` headers) — Phase 1/2 emission for those
  blocks already matches MuseScore's terseness.
- Adding new MuseScore `<Style>` fields beyond what `ScoreStyle`
  currently models (page geometry, spatium, header/footer, page
  number).

## Design

### Part A — `<Style>` skip-if-default emission

#### Core (no changes)

`SheetMusicCore.ScoreStyle.museScoreDefaults` already exists and
matches MuseScore's documented defaults (1.75 mm spatium, A4 page,
`HeaderFooter.museScoreDefaults`, `PageNumberStyle.museScoreDefaults`,
etc.). It is reused as the canonical defaults source. No new core
types or properties.

`MSCXDecoder+Style` already starts from `ScoreStyle.museScoreDefaults`
and overlays parsed values, so any field absent from input XML
already round-trips back to the same default value the encoder will
now elide.

#### `MSCXEncoder+Style.swift` changes

Switch every per-field `children.append(...)` call to a guarded form:
emit a child only when the value differs from the corresponding
`ScoreStyle.museScoreDefaults` field. Add a single private helper:

```swift
private func emitIfNotDefault<T: Equatable>(
    _ name: String,
    _ value: T,
    default defaultValue: T,
    formatter: (String, T) -> XMLTreeNode,
    into children: inout [XMLTreeNode]
)
```

`value == defaultValue` is a no-op; otherwise `formatter(name, value)`
is appended. Existing per-type formatters (`double`, `int`, `bool`,
`text`) are passed in directly.

Field-by-field rules:

- **Page layout fields** (`pageWidth`, `pageHeight`,
  `pagePrintableWidth`, `pageOddTopMargin`,
  `pageOddBottomMargin`, `pageOddLeftMargin`, `pageEvenTopMargin`,
  `pageEvenBottomMargin`, `pageEvenLeftMargin`, `pageTwosided`):
  guarded against `PageLayout.museScoreA4`'s corresponding fields.
- **Spatium**: **always emitted** as `<spatium>` (lowercase, matching
  the existing encoder), even when equal to default 1.75 mm. MuseScore
  Studio's own writer also always emits a spatium anchor; preserving
  that keeps third-party readers happy. (The decoder accepts both
  `<Spatium>` and `<spatium>`; the encoder picks the lowercase form
  the existing implementation already produces.)
- **Header / Footer**:
  - The toggle flags (`showHeader`, `headerFirstPage`,
    `headerOddEven`, plus the footer equivalents) are guarded
    against `HeaderFooter.museScoreDefaults`.
  - Odd-side text triplet (`oddHeaderL/C/R`, `oddFooterL/C/R`),
    `*FontFace`, `*FontSize`, `*FontStyle`: guarded against the
    default's corresponding fields.
  - Even-side text triplet (`evenHeaderL/C/R`, `evenFooterL/C/R`):
    skipped entirely when `oddEvenDifferent == false` (matches
    MuseScore — even-side fields are dead state in that mode); when
    `oddEvenDifferent == true`, guarded against defaults like the
    odd side.
- **Page number**: `showPageNumber`, `showPageNumberOne`,
  `pageNumberOddEven`, `pageNumberFontFace`, `pageNumberFontSize`
  guarded against `PageNumberStyle.museScoreDefaults`.

Field emission order is unchanged from today's
`MSCXEncoder+Style.swift` — only emission is gated.

### Part B — Spanner `<fractions>` round-trip

#### Core change

`Sources/SheetMusicCore/Score/Spanner.swift`: add an optional
`Fraction` field, defaulting to `nil`.

```swift
public struct Spanner: Sendable, Equatable {
    public var kind: Kind
    public var rawType: String
    public var nextMeasuresOffset: Int
    /// MuseScore `<next><location><fractions>N/D</fractions></location></next>`
    /// inside a `<Spanner>`. Optional because most cross-measure
    /// spanners only emit `<measures>` (whole-measure offsets); the
    /// non-nil case is spanners that end mid-measure.
    public var nextFractionsOffset: Fraction?
    public var voltaEndings: [Int]
    public var visible: Bool

    public init(
        kind: Kind,
        rawType: String,
        nextMeasuresOffset: Int = 0,
        nextFractionsOffset: Fraction? = nil,
        voltaEndings: [Int] = [],
        visible: Bool = true
    )
}
```

The new parameter has a default value, so existing call sites stay
source-compatible.

#### MSCX changes

`MSCXDecoder+Spanner.swift`: read `<next><location><fractions>` text
via `Fraction(mscxString:)` and store on `Spanner.nextFractionsOffset`.
`<measures>` reading is unchanged.

`MSCXEncoder+Spanner.swift`: rework `locationWrapper` so the `<next>`
wrapper is emitted when **either** `nextMeasuresOffset != 0` or
`nextFractionsOffset != nil`. The inner `<location>` carries:

- `<fractions>N/D</fractions>` (only when `nextFractionsOffset != nil`)
- `<measures>N</measures>` (only when `nextMeasuresOffset != 0`)

Element order: `<fractions>` before `<measures>`, matching MuseScore's
own writer (`engraving/types/location.cpp::Location::write`). End-side
spanners (`visible == false`, only `<prev/>`) are unchanged.

## Round-trip guarantees

After this change:

- For any `Score` produced by `MSCXParser.parse`, the relation
  `MSCXParser.parse(MSCXEncoder.encode(score)) == score` continues to
  hold for every field both sides understand. The decoder fills
  `<Style>` defaults on absent input; the encoder now elides those
  same defaults; re-parsing fills them back. Spanner
  `nextFractionsOffset` survives via the new field.
- The XML tree produced by re-encoding becomes notably smaller for
  scores written by MuseScore Studio (which omit defaults). Scores
  whose Style differs from defaults round-trip with full fidelity.

## Tests

Target file additions in `Tests/SheetMusicTests/`:

- `MSCXEncoderStyleCompactnessTests.swift` (new):
  - **Default `<Style>` emits only `<spatium>`.** Build a `Score` with
    `style = ScoreStyle.museScoreDefaults`, encode, parse the result,
    inspect the `<Style>` element's children. Expect exactly one
    child: `<spatium>` (the always-emit anchor).
  - **Selective overrides emit only the changed field.** Override
    one field (e.g. `pageLayout.width = 12.0`), encode, assert the
    `<Style>` block contains exactly `<spatium>` plus
    `<pageWidth>12.0</pageWidth>`.
  - **`oddEvenDifferent == false` suppresses `evenHeader*`.** Default
    Style → no even-side fields appear.
  - **`oddEvenDifferent == true` re-emits even-side fields.** Build a
    Style with `header.oddEvenDifferent = true` and an `even.left =
    "X"`, assert `<evenHeaderL>X</evenHeaderL>` appears.
- `MSCXEncoderSpannerFractionsTests.swift` (new):
  - **Round-trip a hand-built spanner with `<fractions>`.** Construct
    minimum `<Score>` XML (string literal) carrying a single
    `<Spanner type="HairPin"><HairPin/><next><location><fractions>1/4</fractions><measures>1</measures></location></next></Spanner>`,
    parse, locate the spanner, assert
    `nextFractionsOffset == Fraction(1, 4)` and
    `nextMeasuresOffset == 1`.
  - **Round-trip preserves both fields through encode.** Encode the
    parsed score, reparse, assert equality of both fields.
  - **Existing-shape spanners (no `<fractions>`) keep `nil`.** Parse
    a `<measures>`-only spanner from existing fixtures; assert
    `nextFractionsOffset == nil`.

Existing suites unchanged: `MSCXEncoderStyleTests.swift`,
`MSCXEncoderSpannersTests.swift`, `MSCXEncoderScoreFrameTests.swift`,
`MSCXRoundTripTests.swift`, all 710 currently-green tests.

## Risks

- **Field ordering when nothing is emitted.** Today's encoder always
  emits the page-layout block, then `<spatium>`, then header / footer
  / page number. With every field gated, only `<Spatium>` is
  guaranteed to appear. The order between gated children is preserved
  by their declaration order in `appendPageLayout` etc., so any
  user-set field appears in the same relative position as today.
- **`Equatable` for `Double`.** Page-layout fields are `Double` and
  exact-equality compared. `ScoreStyle.museScoreDefaults` literals
  (`1.75`, A4 dimensions in inches) are exactly representable in the
  decoder path because the decoder either reads the same literal
  encoder output or doesn't touch the field. No fuzziness expected.
- **Spanner encoding order.** `<fractions>` then `<measures>` mirrors
  MuseScore's writer; if MuseScore's parser is order-tolerant either
  ordering would round-trip, but matching upstream keeps diffs
  against MuseScore Studio output cleaner.
- **No fixture currently exercises spanner `<fractions>`.** New
  test uses an inline minimum-XML construction. If a real fixture
  surfaces later, prefer migrating the test to it.

## Out of scope reminders

Phase 3 (a) — defaults for hand-built `Score` (channel CCs, instrument
templates, eid generation, "what is a sensible default `Score()`?")
— remains deferred to its own spec. This spec is a polish pass on
already-parsed scores only.

## References

- Phase 1 spec: `docs/superpowers/specs/2026-05-07-mscx-export-design.md`
- Phase 2 follow-up memory: see project memory
  `project_mscx_export_phase2_followups.md`
- Encoder root: `Sources/SheetMusicMSCX/Encoders/MSCXEncoder+Style.swift`
- Spanner type: `Sources/SheetMusicCore/Score/Spanner.swift`
- Spanner encoder/decoder:
  `Sources/SheetMusicMSCX/{Encoders,Decoders}/MSCXEncoder+Spanner.swift`,
  `MSCXDecoder+Spanner.swift`
- MuseScore reference: `engraving/types/location.cpp::Location::write`
  (for `<fractions>`/`<measures>` element order)
