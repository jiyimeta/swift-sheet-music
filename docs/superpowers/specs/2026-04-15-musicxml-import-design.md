# MusicXML import — design

Status: proposed
Date: 2026-04-15
Target libraries: new `SheetMusicMusicXML` (library product) + new `SheetMusicXMLTools` (internal target); existing `SheetMusicCore`, `SheetMusicMSCX`, `SheetMusic` (façade)

## Motivation

MusicXML is the de-facto interchange format for engraved notation:
MuseScore, Finale, Sibelius, Dorico, and every major notation editor
import and export it. Today `swift-sheet-music` can only ingest
MuseScore's own `.mscx`, which limits consumers that receive scores
from other sources. Adding `.musicxml` / `.mxl` import closes that gap
and brings the package into parity with the broader ecosystem.

MuseScore's own `importexport/musicxml/tests/musicxml_tests.cpp`
exposes ~85 pure import cases via the `musicXmlImportTestRef` helper:
each reads `testFoo.xml`, writes MSCX, and compares byte-for-byte
against `testFoo_ref.mscx`. Because `SheetMusicMSCX` has no writer, we
cannot reproduce that exact pipeline. We instead compare **semantic
equivalence** — the same pattern already established by
`MidiSemanticComparison.swift` — by parsing both inputs into `Score`
structs and requiring equality.

The MuseScore submodule (`MuseScore/src/importexport/musicxml/`) is
used only as an **algorithmic reference** — no code is copied — per
CLAUDE.md (`MuseScore/` is GPL and dev-only; `Sources/` stays MIT).

## Scope (this spec)

- **Import only.** No MusicXML writer in this round.
- **`<score-partwise>` only.** `<score-timewise>` is explicitly rejected.
- **Both `.musicxml` and `.mxl`** entry points on day one.
- A **16-case fixture seed** drawn from MuseScore's `musicXmlImportTestRef`
  set, staged in 5 phases to align `SheetMusicCore` extensions with
  fixture requirements.
- The new library is named **`SheetMusicMusicXML`** (not `SheetMusicXML`)
  to avoid aliasing with MSCX's internal XML helpers and with Apple's
  MusicKit-family naming.

## Non-goals

- **Export.** `Score → MusicXML` serialization is deferred to a later
  spec; the decoder set is large and independent.
- **`<score-timewise>`.** XSLT-round-trippable in theory, but MuseScore
  and the test fixtures are partwise; timewise adds decoder branching
  for essentially no real-world value.
- **Layout metadata.** `<print>`, `<page-layout>`, `<system-layout>`,
  `<staff-layout>`, credits geometry, positioning attributes (`default-x`,
  `default-y`, `relative-x`, …), explicit beams, system/page breaks,
  staff size and spacing.
- **URL-based API.** `parse(contentsOf: URL)` is a follow-up. Until then
  callers pass `Data`. (A TODO comment in `MusicXMLParser` points at the
  future overload.)
- **Rich chord-symbol / figured-bass / technical / fingering / advanced
  ornament modeling.** Fixtures that require these are excluded from the
  seed.
- **MIDI-side augmentation from MusicXML.** `<sound tempo>` /
  `<sound dynamics>` are honoured when they feed existing `Tempo` /
  `Dynamic` types, otherwise ignored.
- **Copying code from `MuseScore/`.** Algorithmic reference only.
- **Async variants.** All I/O is synchronous, matching existing API.

## Architecture

### Package.swift diff

```
products: [
    .library(name: "SheetMusic",            targets: ["SheetMusic"]),
    .library(name: "SheetMusicCore",        targets: ["SheetMusicCore"]),
    .library(name: "SheetMusicMSCX",        targets: ["SheetMusicMSCX"]),
    .library(name: "SheetMusicMIDI",        targets: ["SheetMusicMIDI"]),
  + .library(name: "SheetMusicMusicXML",    targets: ["SheetMusicMusicXML"]),
]
targets: [
    .target(name: "SheetMusicCore"),
  + .target(name: "SheetMusicXMLTools"),                                         // internal, no product
    .target(name: "SheetMusicMSCX",         dependencies: ["SheetMusicCore",
                                                           "SheetMusicXMLTools",
                                                           "ZIPFoundation"]),
  + .target(name: "SheetMusicMusicXML",     dependencies: ["SheetMusicCore",
                                                           "SheetMusicXMLTools",
                                                           "ZIPFoundation"]),
    .target(name: "SheetMusicMIDI",         dependencies: ["SheetMusicCore"]),
    .target(name: "SheetMusic",             dependencies: ["SheetMusicCore",
                                                           "SheetMusicMSCX",
                                                           "SheetMusicMIDI",
                                                           "SheetMusicMusicXML"]),
    .testTarget(name: "SheetMusicTests",    dependencies: [..., "SheetMusicMusicXML"]),
]
```

`SheetMusicXMLTools` is an **internal target** (not a library product).
This does not violate CLAUDE.md's "no intermediate category libraries"
rule — that rule governs *published library products*. Shared internal
targets are conventional SwiftPM.

### Dependency graph

```
SheetMusic (umbrella)
   │
   ├─→ SheetMusicCore
   ├─→ SheetMusicMIDI     → Core
   ├─→ SheetMusicMSCX     → Core, SheetMusicXMLTools*, ZIPFoundation
   └─→ SheetMusicMusicXML → Core, SheetMusicXMLTools*, ZIPFoundation

* internal target (not a library product)
```

### File layout

```
Sources/SheetMusicXMLTools/
├── XMLNode.swift                    ← moved from SheetMusicMSCX/XML/
└── XMLTreeParser.swift              ← moved from SheetMusicMSCX/XML/

Sources/SheetMusicMSCX/
├── MSCXParser.swift                 unchanged
├── Decoders/*.swift                 unchanged behaviour; +`import SheetMusicXMLTools`
└── (XML/ directory removed)

Sources/SheetMusicMusicXML/
├── MusicXMLParser.swift             public façade
├── MusicXMLContainer.swift          public helper for `.mxl` rootfile discovery
├── MXL/
│   └── MXLReader.swift              ZIPFoundation + container.xml resolution
├── Decoders/
│   ├── MusicXMLDecoder.swift        root dispatch (score-partwise)
│   ├── MusicXMLDecoder+Part.swift
│   ├── MusicXMLDecoder+Measure.swift
│   ├── MusicXMLDecoder+Attributes.swift     clef / key / time / divisions / transpose
│   ├── MusicXMLDecoder+Note.swift           note / chord / grace / tuplet / tie
│   ├── MusicXMLDecoder+Barline.swift
│   ├── MusicXMLDecoder+Direction.swift      dynamic / tempo / wedge (spanner)
│   ├── MusicXMLDecoder+Notations.swift      tied / slur / fermata / arpeggio / glissando
│   └── MusicXMLDecoder+Jump.swift           D.S. / D.C. / Coda / Fine (Measure-level)
└── Internal/
    ├── DivisionsContext.swift       <divisions> → Fraction
    └── MusicXMLDuration.swift       <type>+<dot>+<time-modification> → NoteDuration
```

### Fallout on existing code

- `SheetMusicMSCX/XML/` removed; MSCX decoders gain a single
  `import SheetMusicXMLTools` line. Public API unchanged. Existing 48
  tests must remain green.
- Spec implementation is split into 6 PRs (see "Implementation phases"
  below), the first of which is the risk-free extraction.

## Public API

### `SheetMusicMusicXML`

```swift
public enum MusicXMLParser {
    /// Uncompressed MusicXML (`<score-partwise>` root).
    public static func parse(_ data: Data) throws -> Score

    /// Compressed `.mxl` archive. Resolves the rootfile from
    /// `META-INF/container.xml`, then delegates to `parse(_:)`.
    public static func parse(mxlData: Data) throws -> Score

    // TODO: parse(contentsOf: URL) — future spec (URL-based API).
}

public enum MusicXMLContainer {
    public struct RootFile: Sendable, Equatable {
        public let path: String
        public let mediaType: String?   // "application/vnd.recordare.musicxml+xml" etc.
    }

    /// Entries discovered in a .mxl archive's META-INF/container.xml,
    /// in document order. `parse(mxlData:)` uses the first partwise entry
    /// (mediaType matching MusicXML, else the first rootfile).
    public static func rootFiles(mxlData: Data) throws -> [RootFile]
}
```

Return type is always `Score`. No `public` MusicXML element types are
surfaced.

### `SheetMusic` façade

```swift
public enum SheetMusic {
    // existing
    public static func loadScore(mscxData: Data) throws -> Score
    public static func exportMIDI(score: Score) throws -> Data

    // added
    public static func loadScore(musicXMLData: Data) throws -> Score
    public static func loadScore(mxlData: Data) throws -> Score
}
```

`SheetMusic.swift` gains `@_exported import SheetMusicMusicXML`.

## Error model

Reuse `SheetMusicCore/SheetMusicError.SheetMusicError.malformedScore(String)`
with a stable message prefix so callers can coarse-filter if they must.
No new enum cases.

| Situation | Message |
|---|---|
| Root element not `<score-partwise>` or `<score-timewise>` | `MusicXML: <score-partwise> root element not found` |
| `<score-timewise>` root | `MusicXML: unsupported <score-timewise> variant` |
| `<part-list>`, `<part id>`, or first `<divisions>` missing | `MusicXML: <…> is required` |
| `<duration>` not numeric / conflicting with type+dots+time-modification | permissive: adopt `<duration>`, fall back to `NoteDuration.fraction` |
| MXL archive corrupt (ZIPFoundation throws) | `MXL: \(underlyingDescription)` |
| `META-INF/container.xml` missing or empty | `MXL: container.xml missing or has no rootfiles` |
| rootfile path not present in archive | `MXL: rootfile '\(path)' not found in archive` |

Unknown elements inside a `<voice>` (or anywhere else) are **silently
skipped**, matching the permissive posture of `MSCXDecoder+Voice.swift`.

## Decoding pipeline

### `.musicxml` flow

```
Data
  │ XMLTreeParser.parse
  ▼
XMLNode (root)
  │ name must be "score-partwise" (timewise explicitly rejected)
  ▼
MusicXMLDecoder.decode(root) -> Score
  │
  ├─ <work>, <identification>   → Score.metaTags
  ├─ <part-list>/<score-part>   → Part[] + Instrument / InstrumentChannel
  └─ <part id="Pn">             → StaffContent
         └─ <measure number="k">→ Measure
                 ├─ <attributes>  → Clef / KeySignature / TimeSignature / divisions / staves / transpose
                 ├─ <direction>   → Tempo / Dynamic / Spanner(wedge)
                 ├─ <barline>     → BarLine (incl. end-repeat, volta start/stop)
                 ├─ <note>        → Chord (folded via <chord/>) / Note; grace, tie, fermata, articulation, lyric attached here
                 ├─ <backup>      → rewind voice cursor by N divisions
                 ├─ <forward>     → advance cursor (emit Rest if same voice)
                 ├─ <sound>       → Tempo / Dynamic (minimum)
                 └─ <print>       → ignored (layout out of scope)
```

### Timing: `<divisions>`

MusicXML measures intra-bar positions in integer `<divisions>` (a
quarter note = N ticks), redeclared per part / per measure. A
`DivisionsContext` tracks the current value and converts:

```swift
struct DivisionsContext {
    var perQuarter: Int
    func fractionOfWhole(_ duration: Int) -> Fraction {
        // duration / (4 * perQuarter), reduced
    }
}
```

`MusicXMLDuration` builds `NoteDuration` from `<type>` + repeated
`<dot>` + `<time-modification>` (tuplets), cross-checks against
`<duration>`, and falls back to `.fraction(fractionOfWhole(duration))`
on mismatch — mirroring `MusicXmlParserPass2::note` in MuseScore.

### Chord folding

```
[<note pitch=C>, <note pitch=E chord/>, <note pitch=G chord/>]
→ Chord(notes: [C, E, G])
```

`<grace/>` flagged notes decode as ordinary `Chord`s for this spec (no
`isGrace` flag yet — reserved for a later phase, see "Not added"
below). Seed fixtures that carry grace notes only incidentally are
expected to tolerate this; any fixture whose semantic equivalence
hinges on grace-vs-normal distinction is dropped from the seed.

### Voice, `<backup>`, `<forward>`

Each `<note>` carries `<voice>N</voice>`; we append to that voice's
cursor. `<backup duration="N">` rewinds the measure cursor by `N`
divisions so subsequent notes in a *different* voice start at the
correct time. `<forward>` advances the cursor and emits a `Rest` for
the same voice (or nothing if `<forward>` precedes a new `<voice>`).
Reference: `MusicXmlParserPass2::measure`.

### `.mxl` flow

```
Data
  │ ZIPFoundation.Archive(data:, accessMode: .read)
  ▼
Archive
  │ read "META-INF/container.xml"
  │ parse <rootfiles>/<rootfile full-path="…" media-type="…">
  │   prefer media-type = "application/vnd.recordare.musicxml+xml"
  │   else take the first rootfile (back-compat)
  ▼
extract rootfile entry → Data
  │
  ▼
MusicXMLParser.parse(_:)
```

## Core model extensions

**Invariant**: Score has two producers (MSCX decoder, MusicXML decoder)
and one consumer (equality comparison in tests). Any new Score field
**must be decoded by both producers** or semantic-equivalence tests
will fail for false reasons. Each Phase below adds Core type(s) + both
decoders in lockstep.

### New types added under `Sources/SheetMusicCore/Score/` by this spec

| File | Purpose | Phase |
|---|---|---|
| `Fermata.swift` | `<notations><fermata>` shape | 3 |
| `Jump.swift` | D.C. / D.S. / D.C. al Fine / D.C. al Coda / D.S. al Fine / D.S. al Coda at measure-right | 2 |
| `Marker.swift` | Segno / Coda / Fine / ToCoda at measure-left | 2 |

### Field additions on existing types (all defaulted → source-compatible)

| Type | Added fields | Phase |
|---|---|---|
| `Note` | `tieForward: Int? = nil`, `tieBack: Int? = nil` — `nil` = no tie, `.some(n)` = tie with MusicXML's `<tie number="n">` (defaults to `1` when unnumbered). `Int?` chosen up front to cover `importTie4`-style overlapping ties. | 1 |
| `Chord` | `fermata: Fermata? = nil` | 3 |
| `Rest` | `fermata: Fermata? = nil` | 3 |
| `Spanner.Kind` | `case glissando` | 4 |
| `Measure` | `markers: [Marker] = []`, `jumps: [Jump] = []` | 2 |
| `Score` | no new fields (title / composer / copyright go into existing `metaTags`) | — |

### Not added in this spec (explicit YAGNI — reserved for later phases)

These are **not added** to `SheetMusicCore` by any of the 6 PRs in this
spec. The corresponding fixtures are excluded from the seed (see
"Explicit fixture exclusions" below). When a future spec adopts them,
both the MSCX and MusicXML decoders must learn them together, per the
invariant above.

- `Lyric` and any `Chord.lyrics` field — `<lyric>` / `<syllabic>` /
  `<text>`.
- `Articulation` and any `Chord.articulations` field — per-note
  staccato / accent / breath mark / ornaments.
- `Tremolo` and any `Chord.tremolo` field — single / two-note tremolo.
- `Chord.isGrace` / `GraceStyle` — `<grace/>`. `<grace/>` notes are
  present in some Phase 0/1 fixtures only in passing; they decode as
  ordinary `Chord`s for now. If this proves to cause semantic-diff
  failures during Phase 0, that fixture is dropped from the seed per
  the spec's "reshape rather than force-fit" rule.
- Layout (`<print>`, `<page-layout>`, positioning attributes).
- `<harmony>` (chord symbols), `<figured-bass>`.
- Rich ornament MIDI expansion.
- `<technical>` (fingering, string, fret).
- Part bracket / system grouping.

## Fixture seed (16 cases, 5 phases)

MuseScore's `musicXmlImportTestRef` set contains 85 `*.xml` /
`*_ref.mscx` pairs. The table below is the initial seed; fixtures that
turn out to require more than the nominated Core extension during
implementation are **dropped from the seed** (not force-fit).

| # | Fixture | Phase | New Core work | Purpose |
|---|---|---|---|---|
| 1 | `testArpOnRest` | 0 | — | `<arpeggiate>` on rest |
| 2 | `testArpCrossVoice` | 0 | — | `<arpeggiate>` across voices |
| 3 | `testBarlineLoc` | 0 | — | `<barline location>` |
| 4 | `testCopyrightScale` | 0 | — | `<identification>` → `metaTags` |
| 5 | `testDurationLargeError` | 0 | — | permissive duration fallback |
| 6 | `testPartNames` | 0 | — | `<part-list>` → `Part.name` |
| 7 | `testUnnecessaryBarlines` | 0 | — | redundant barline dedupe |
| 8 | `importTie1` | 1 | `Note.tieForward/Back` | `<tie>`, `<tied>` single |
| 9 | `importTie2` | 1 | (same) | multiple ties |
| 10 | `importTie3` | 1 | (same) | partial-chord ties |
| 11 | `importTie4` | 1 | (same, numbered) | numbered tie across voices |
| 12 | `testUnterminatedTies` | 1 | (same) | permissive unterminated tie |
| 13 | `testDSalCoda` | 2 | `Jump` / `Marker` / `Measure.jumps`,`markers` | D.S. al Coda |
| 14 | `testCodaHBox` | 2 | (same) | Coda symbol |
| 15 | `testTempoLineFermata` | 3 | `Fermata` + `Chord/Rest.fermata` | tempo + fermata |
| 16 | `testGlissFall` | 4 | `Spanner.Kind.glissando` | `<slide>` / `<glissando>` |

### Explicit fixture exclusions

The following classes of fixtures are **out of seed** and reserved for
follow-up PRs; do not attempt them in this spec:

- **Lyrics**: `testLyric*`, `testElision`, `testSecondVoiceMelismata`,
  `testSticking*`.
- **Inferred text / credits / dynamics**: `testInferred*` (all
  `testInferredCredits*`, `testInferredCrescLines*`,
  `testInferredDynamics*`, `testInferredFingerings`,
  `testInferredRights`, `testInferredTechnique`,
  `testInferredTempoText*`, `testInferCodaII`, `testInferFraction`,
  `testInferSegnoII`), `testTextOrder`, `testTextQuirkInference`,
  `testTitleSwap*`. (Note: `testCopyrightScale` is **in** the seed —
  it only exercises plain `<identification>` → `metaTags`, not
  credit-geometry inference.)
- **Chord symbols / figured bass**: `testChordSymbols*`.
- **Percussion / drumsets**: `testImportDrums*`, `testMS3KitAndPerc`.
- **Ornaments & tremolo**: `testBuzzRoll*`, `testTremolo*`.
- **Beam modeling**: `testBeamModes`.
- **Staff / system grouping**: `testSystemBrackets3`,
  `testSystemObjectStaves`, `testBracketTypes`, `testStaffEmptiness`,
  `testExcessHiddenStaves`.
- **Placement / offsets / layout**: `testPlacementDefaults`,
  `testPlacementOffsetDefaults`, `testNegativeOffset`, `testWedgeOffset`.
- **Sibelius / Dolet / Finale quirk inference**: `testSib*`,
  `testDolet*`, `testFinale*`.
- **Misc**: `testNamedNoteheads`, `testMeasureStyleSlash`,
  `testStringmute`, `testTimeTick`, `testPedalChangesBroken`,
  `testTempoTextSpace*`, `testVoltaHiding`, `testNoteAttributes2`.

## Testing strategy

### Files

```
Tests/SheetMusicTests/
├── MusicXMLImportTests.swift                    new @Test suite (16 cases + MXL)
├── Helpers/
│   ├── MidiSemanticComparison.swift             (existing)
│   ├── ScoreSemanticComparison.swift            new: tolerant Score equality
│   └── MusicXMLFixtureLoader.swift              new: Bundle .xml / _ref.mscx loader
└── Resources/
    └── musicxml/
        ├── testArpOnRest.xml
        ├── testArpOnRest_ref.mscx
        … (16 × 2 = 32 files)
```

### ScoreSemanticComparison

Two-layer design:

1. **Direct** `Score == Score`. Expected to pass for most Phase 0/1 fixtures.
2. **Tolerated noise** via `ScoreComparisonOptions`:

```swift
struct ScoreComparisonOptions: Sendable {
    /// Some .mscx files carry an implicit initial clef the MusicXML side
    /// does not emit. Enable per fixture with a doc-comment justification.
    var ignoreImplicitInitialClef: Bool = false
    /// Meta-tag keys that differ in spelling between MSCX and MusicXML
    /// (e.g. MusicXML's <rights> vs MSCX's "copyright" key). Enabled
    /// only with justification.
    var ignoreMetaTagKeys: Set<String> = []
}

func expectScoreSemanticEqual(
    _ left: Score,
    _ right: Score,
    options: ScoreComparisonOptions = .init(),
    sourceLocation: SourceLocation = #_sourceLocation
)
```

Every opt-in tolerance must be justified in a doc comment at the
assertion call site (which fixture, why the asymmetry, with a file
path into `MuseScore/` if applicable). Mirrors the existing
`tempomapWithPauses` carve-out in `MidiSemanticComparison`.

On failure, emit a structured diff (which `Part`, which `Measure`,
which `VoiceElement`, what differs) rather than full Score dumps —
dumps are unreadable at this size.

### MXL smoke testing

No `.mxl` fixture is shipped. Instead the test builds one at runtime
with ZIPFoundation, wrapping a simple in-seed XML fixture
(`testCopyrightScale.xml` recommended):

```swift
@Test("mxl: container.xml + rootfile round-trips")
func mxl_smoke() throws {
    let xml = try MusicXMLFixtureLoader.xml(named: "testCopyrightScale")
    let mxl = try MXLTestBuilder.wrap(xml: xml, entryName: "score.xml")
    let fromXml = try MusicXMLParser.parse(xml)
    let fromMxl = try MusicXMLParser.parse(mxlData: mxl)
    expectScoreSemanticEqual(fromXml, fromMxl)
}

@Test("mxl: missing container.xml fails with stable message")
func mxl_missing_container() throws { /* build zip lacking META-INF/container.xml */ }

@Test("mxl: rootfile path absent from archive fails")
func mxl_rootfile_absent() throws { /* container.xml references a missing entry */ }
```

### Fixture provenance

The 32 fixture files under `Tests/SheetMusicTests/Resources/musicxml/`
are byte-identical copies from `MuseScore/src/importexport/musicxml/tests/data/`.
They are GPL-3.0. Per project policy (`CLAUDE.md` + existing
`Tests/SheetMusicTests/Resources/LICENSE` + `NOTICE`), the fixtures:

- live only in the test target, not in any `Sources/` product;
- are documented in an updated `Tests/SheetMusicTests/Resources/LICENSE`
  that lists the `musicxml/` directory explicitly;
- are named in a new paragraph of `NOTICE` describing MusicXML fixture
  provenance.

## Risks and open questions

1. **Implicit MSCX elements causing false diff.** MuseScore saves
   implicit initial clefs, implicit key signatures, and occasional
   volta ornamentation that MusicXML does not emit verbatim. Phase 0's
   7 fixtures are the early-warning system; tolerated-noise switches
   on `ScoreComparisonOptions` absorb these with per-fixture
   justification.
2. **MetaTag key naming divergence.** MusicXML's `<identification>`
   maps to MSCX's `metaTag name="composer|copyright|…"` keys, but
   canonical names may differ (e.g. MusicXML's `<rights>` vs MSCX's
   `copyright`). `testCopyrightScale` forces this question early.
3. **Tie numbering.** If `importTie4` relies on MusicXML's `<tie
   number="N">` to disambiguate overlapping ties, the initial `Bool`
   flags are insufficient and must be promoted to `Int?` (already
   baked into the spec above).
4. **Jump/Marker vs. end-repeat overlap.** Measure-level `Jump`/`Marker`
   and `BarLine`'s end-repeat coexist in MuseScore as distinct
   concepts; we keep the same separation.
5. **`.mxl` multi-rootfile archives.** No MuseScore fixture exercises
   this, so `MusicXMLContainer.rootFiles` is covered only by
   hand-built smoke tests.
6. **XMLTools extraction regression.** Phase's PR 1 is a pure
   structural move; correctness is verified by the existing 48 MSCX /
   MIDI tests staying green.

## Implementation phases

Ship in 6 PRs, each independently reviewable and green. Do not squash:
this is the CLAUDE.md-preferred flow ("One responsibility per PR").

| PR | Content | Tests added / passing |
|---|---|---|
| 1 | Extract `SheetMusicXMLTools` target; rewire MSCX decoders. No behaviour change. | 0 new; existing 48 pass |
| 2 | `SheetMusicMusicXML` skeleton + Phase 0 (7 Basics fixtures) + ScoreSemanticComparison + MXL smoke (1 positive, 2 negative) + SheetMusic façade additions. | +10 |
| 3 | Phase 1: `Note.tieForward/Back` + Tie decoding in both MSCX and MusicXML + 5 tie fixtures. | +5 |
| 4 | Phase 2: `Jump` / `Marker` / `Measure.jumps,markers` + both-decoder support + 2 jump fixtures. | +2 |
| 5 | Phase 3: `Fermata` + `Chord.fermata` / `Rest.fermata` + both-decoder support + 1 fermata fixture. | +1 |
| 6 | Phase 4: `Spanner.Kind.glissando` + both-decoder support + 1 glissando fixture. | +1 |

End state: 48 existing + 19 new = **67 tests, 100% green**.
