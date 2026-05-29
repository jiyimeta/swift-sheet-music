# MSCX parser diagnostics — design

**Status:** approved 2026-05-29
**Scope:** `SheetMusicMSCX` decoder path only (`MSCXParser` / `MSCZReader` and `MSCXDecoder+*.swift`)
**Motivation:** a real user reported that an `.mscz` file failed to open with `Tremolo unknown <subtype> r64`. The chord's notes, duration, and stem were all valid — only the (optional) tremolo embellishment used a subtype the decoder didn't recognise. Throwing rejected the whole file rather than dropping a single decoration. This spec generalises the lesson into a parser-wide policy and an API for surfacing non-fatal anomalies.

## Background — current state

`Sources/SheetMusicMSCX/Decoders/` contains ~20 `throw SheetMusicError.malformedScore(...)` sites. Some are genuinely structural (a missing `<pitch>` cannot be defaulted). Others — like `Tremolo` unknown `<subtype>` — abort the parse for an embellishment whose absence the rest of the model trivially tolerates.

The codebase also already has a precedent for the lighter path: `mscxDecoderLogger.warning(...)` calls in `MSCXDecoder+Breath.swift` and `MSCXDecoder+Score.swift` use `os.Logger` to record recoverable anomalies. But those warnings are invisible to API callers — they only land in the system console.

The project's `CLAUDE.md` codifies a "permissive parser" stance for **unknown elements** inside `<voice>` but does not address **unknown enum values** inside known elements. This spec fills that gap.

## Goals

1. Make optional, embellishment-class decode failures non-fatal — the score loads, the offending decoration drops, and a `ScoreDiagnostic` records what happened.
2. Surface these diagnostics through a new `parseWithDiagnostics(...)` API without breaking the existing `parse(...) -> Score` callers.
3. Establish a clear policy (Structural → throw / Embellishment → drop+diagnostic / Cosmetic → silent default) so future decoder additions follow the rule without re-discovery.
4. Route existing `mscxDecoderLogger.warning(...)` calls through the same collector so that anomalies already surfaced to `os_log` also become first-class diagnostics — without changing their console behaviour.

## Non-goals (deferred to future PRs)

- MusicXML / MXL parser side. The same pattern applies but is out of scope.
- Encoder / MIDI renderer / Layout. Diagnostics from those layers would need their own collector wiring.
- "Default-by-inference" for currently-structural throws (`<durationType>` missing on Rest / Chord, `<tpc>` missing on Note). These have semantic risk and warrant separate discussion.
- Strict mode (an opt-in flag that re-promotes diagnostics to throws for tests). The data model supports it; surfacing the toggle is a follow-up.
- Localisation of `ScoreDiagnostic.message`.
- JNI bridge plumbing for Android consumers of diagnostics.

## Architecture

### `ScoreDiagnostic` (new, in `SheetMusicCore`)

```swift
/// Non-fatal anomaly observed while parsing a score. Collected by
/// `MSCXParser.parseWithDiagnostics(...)` /
/// `MSCZReader.parseWithDiagnostics(...)` instead of being thrown, so
/// callers can recover partial data and surface a warning UI.
public struct ScoreDiagnostic: Sendable, Hashable {
    public enum Severity: Sendable, Hashable {
        case warning  // recoverable: element dropped or defaulted
        case info     // notable but expected (e.g. MS2 compat path)
    }

    public let severity: Severity
    /// Stable, machine-readable identifier. Dotted namespace under
    /// `mscx.<element>.<reason>` — e.g. `"mscx.tremolo.unknownSubtype"`.
    /// Useful for downstream filtering / suppression / localisation.
    public let code: String
    /// Human-readable English message. Localisation is the caller's job.
    public let message: String
    /// Best-effort location string — e.g. `"measure 12, voice 1, Tremolo"`.
    /// `nil` when the producer cannot derive a location cheaply.
    public let location: String?
}
```

Lives in `Sources/SheetMusicCore/ScoreDiagnostic.swift`. Goes in Core (not MSCX) because future MusicXML / encoder layers will reuse the same type.

`SheetMusicError` is **not** extended — diagnostics are a parallel channel, not an error case. This preserves the "Errors via `throws`" convention from `CLAUDE.md`.

### `MSCXParseResult` (new, in `SheetMusicMSCX`)

```swift
public struct MSCXParseResult: Sendable {
    public let score: Score
    public let diagnostics: [ScoreDiagnostic]
}
```

This stays in `SheetMusicMSCX` rather than Core because Core does not import any I/O. MusicXML will eventually grow its own `MusicXMLParseResult` analogue.

### Public API

```swift
extension MSCXParser {
    // Existing — unchanged
    public static func parse(_ data: Data) throws -> Score
    public static func parse(contentsOf url: URL) throws -> Score

    // New
    public static func parseWithDiagnostics(_ data: Data) throws -> MSCXParseResult
    public static func parseWithDiagnostics(contentsOf url: URL) throws -> MSCXParseResult
}

extension MSCZReader {
    // Existing — unchanged
    public static func parse(_ data: Data) throws -> Score
    public static func parse(contentsOf url: URL) throws -> Score

    // New
    public static func parseWithDiagnostics(_ data: Data) throws -> MSCXParseResult
    public static func parseWithDiagnostics(contentsOf url: URL) throws -> MSCXParseResult
}
```

**Semantic note (important):** the existing `parse(...) -> Score` shares the new drop+diagnostic path internally — it just discards the diagnostics. Concretely:

- A file containing an unknown tremolo subtype now **opens** through both `parse(...)` and `parseWithDiagnostics(...)`.
- `parseWithDiagnostics(...)` is purely about visibility, not loadability.

This means example apps see the loadability improvement immediately, without migrating to the new API. The new API is needed only when callers want to act on diagnostics (banner, log forwarder, telemetry).

### Internal collector

```swift
/// Threaded through decoders during a single parse call. Not Sendable —
/// single-threaded ownership for the lifetime of one parse.
final class MSCXDiagnosticCollector {
    private(set) var entries: [ScoreDiagnostic] = []

    func warn(code: String, message: String, location: String? = nil)
    func info(code: String, message: String, location: String? = nil)
}
```

Lives in `Sources/SheetMusicMSCX/Diagnostics/MSCXDiagnosticCollector.swift`.

The collector is created at the top of each parse call (one per `parse*` invocation) and disposed at the end. To avoid plumbing it through every decoder signature, we use a **task-local-style stash** owned by `MSCXParser`:

```swift
enum MSCXParserContext {
    @TaskLocal static var collector: MSCXDiagnosticCollector?
}
```

The new entry points wrap the existing decode pipeline:

```swift
public static func parseWithDiagnostics(_ data: Data) throws -> MSCXParseResult {
    let collector = MSCXDiagnosticCollector()
    let score = try MSCXParserContext.$collector.withValue(collector) {
        try parse(data) // existing implementation, untouched at the top level
    }
    return MSCXParseResult(score: score, diagnostics: collector.entries)
}
```

Decoders that have something to report read the optional task-local. Decoders that have nothing to report stay untouched. No mass signature change.

### `mscxDecoderLogger` integration

`mscxDecoderLogger.warning(...)` calls in `MSCXDecoder+Breath.swift` (1 site) and `MSCXDecoder+Score.swift` (2 sites) are wrapped in a thin helper:

```swift
// New file: Sources/SheetMusicMSCX/Diagnostics/MSCXDecoderWarn.swift

func mscxDecoderWarn(
    code: String,
    message: String,
    location: String? = nil,
) {
    mscxDecoderLogger.warning("\(code): \(message, privacy: .public)")
    MSCXParserContext.collector?.warn(
        code: code, message: message, location: location,
    )
}
```

Existing call sites switch from `mscxDecoderLogger.warning("…")` to `mscxDecoderWarn(code: "mscx.…", message: "…")`. Console behaviour is preserved (same Logger, same severity), and the same anomaly now also appears in `diagnostics`.

## Categorisation policy

This becomes a project convention, added to `CLAUDE.md` under the "Permissive parser" bullet:

| Element role | Effect of dropping | Decoder behaviour |
| --- | --- | --- |
| **Structural** — pitch, voice structure, time signature, division | Notes vanish or measure length breaks | **throw** `SheetMusicError.malformedScore` |
| **Embellishment** — tremolo, articulation, ornament, fermata, breath, hairpin shape, glissando style | Sound and rhythm intact, only the decoration disappears | **drop the element + emit diagnostic** |
| **Cosmetic** — color, offset, font, stroke style | Visual default substitutes | **silent default** (existing behaviour) |

### Decoder changes in this PR (first pass)

Audit of all 20 throw sites in `Sources/SheetMusicMSCX/Decoders/` yields three conversions:

| File:line | Reason | Action |
| --- | --- | --- |
| `MSCXDecoder+Tremolo.swift:16` | `<Tremolo>` missing `<subtype>` | drop tremolo + `mscx.tremolo.missingSubtype` warning |
| `MSCXDecoder+Tremolo.swift:49` | MS3 `<Tremolo>` unknown `<subtype>` | drop tremolo + `mscx.tremolo.unknownSubtype` warning |
| `MSCXDecoder+Tremolo.swift:67` | MS4 `<TremoloSingleChord>` / `<TremoloTwoChord>` unknown `<subtype>` | drop tremolo + `mscx.tremolo.unknownSubtype` warning |

"Drop tremolo" means returning `nil` from `Tremolo.decode(_:)` and the caller (`MSCXDecoder+Chord.swift`) treating `nil` the same as "no Tremolo child present". The chord itself parses normally.

The 13 structural sites (Note pitch, Score, Division, Part Instrument, Staff pairing, TimeSig, KeySig, two-note tremolo follower) keep their `throw` unchanged. The four boundary sites (Rest / Chord `<durationType>`, Note `<tpc>`) also keep their `throw` for now — moving them to "default by inference" is a deliberate follow-up because the defaulting choice has semantic consequences.

### Existing warnings surfaced as diagnostics

Two existing `mscxDecoderLogger.warning(...)` call sites in `MSCXDecoder+Score.swift` and one in `MSCXDecoder+Breath.swift` are converted to `mscxDecoderWarn(code:message:)`. Suggested codes:

- `mscx.score.unsupportedProgramVersion` (Score.swift line 135)
- `mscx.score.missingProgramVersion` (Score.swift line 152)
- `mscx.breath.unknownSubtype` (Breath.swift line 21)

These now appear in `diagnostics` while still logging to the same `Logger`.

## Test strategy

### New fixture

`Tests/SheetMusicTests/Resources/own/diagnostics-tremolo-unknown-subtype.mscx`

A minimal valid score (1 part / 1 staff / 1 measure / 1 quarter note) carrying `<Tremolo><subtype>r128</subtype></Tremolo>`. Hand-authored, **MIT-licensed**, kept in a dedicated `Resources/own/` sub-directory so its provenance is unambiguous and separable from the GPL-3.0 MuseScore-imported fixtures already in `Resources/`.

A second tiny fixture is **not** added for the missing-subtype case — it can be derived from the same XML at test time using `String` substitution.

### New tests (`Tests/SheetMusicTests/MSCXDiagnosticsTests.swift`)

```swift
@Suite struct MSCXDiagnosticsTests {
    @Test func unknownTremoloSubtype_emitsDiagnostic_andDropsTremolo() throws
    @Test func plainParse_alsoLoadsFileWithUnknownTremolo() throws
    @Test func missingTremoloSubtype_emitsDiagnostic_andDropsTremolo() throws
    @Test func cleanFile_yieldsEmptyDiagnostics() throws
    @Test func diagnosticHasStableCode() throws
    @Test func mscxDecoderWarnAlsoFeedsCollector() throws
}
```

The clean-file check uses an existing GPL fixture (e.g. `midi01.mscx`) to assert that a well-formed score produces zero diagnostics — guarding against accidental diagnostic emission from already-OK paths.

### Existing test impact

- `Tests/SheetMusicTests/TremoloMSCXDecodeTests.swift::unknown_subtype_throws` — currently expects throws. Renamed to `unknown_subtype_emits_diagnostic`, asserts diagnostic + dropped tremolo via the new API. The `r128` token used by this test stays valid as "an unknown subtype" example.
- All other parser tests — unchanged. The 17 structural throw sites are untouched, and existing fixtures contain no unknown enum values.
- `MidiExportTests` — unchanged. Uses `MSCXParser.parse(...)`, which gains the new permissive path but the 12 MuseScore-equivalence fixtures have no unknown values, so diagnostics stay empty and the behaviour is identical.

## File layout summary

```
Sources/SheetMusicCore/
  ScoreDiagnostic.swift                                 (new)

Sources/SheetMusicMSCX/
  MSCXParser.swift                                      (+ parseWithDiagnostics overloads)
  MSCZReader.swift                                      (+ parseWithDiagnostics overloads)
  MSCXParseResult.swift                                 (new)
  Diagnostics/
    MSCXDiagnosticCollector.swift                       (new)
    MSCXParserContext.swift                             (new — TaskLocal holder)
    MSCXDecoderWarn.swift                               (new — Logger + collector helper)
  Decoders/
    MSCXDecoder+Tremolo.swift                           (3 throws → diagnostic + nil)
    MSCXDecoder+Chord.swift                             (handle nil from Tremolo.decode)
    MSCXDecoder+Score.swift                             (2 logger.warning → mscxDecoderWarn)
    MSCXDecoder+Breath.swift                            (1 logger.warning → mscxDecoderWarn)

Tests/SheetMusicTests/
  MSCXDiagnosticsTests.swift                            (new)
  TremoloMSCXDecodeTests.swift                          (rename + rewrite one test)
  Resources/own/
    LICENSE                                             (new — MIT scope for our own fixtures)
    diagnostics-tremolo-unknown-subtype.mscx            (new)

CLAUDE.md                                               (extend the "Permissive parser" bullet)
```

## Open questions resolved during brainstorming

- **API ergonomics** — sibling `parseWithDiagnostics(...)` rather than a breaking single API. Existing callers keep working; new callers opt in. (Section 2.)
- **Format scope** — MSCX/MSCZ only this round. MusicXML follows the same pattern in a future PR. (Section 1.)
- **Throw-site scope** — only the three Tremolo "unknown / missing enum value" sites convert. Structural sites stay as `throw`. Boundary sites (durationType / tpc defaulting) deferred. (Section 3.2.)
- **Logger integration** — `mscxDecoderWarn` wrapper preserves console output and adds the collector entry. No breaking change to existing log consumers. (Section 3.3.)

## Acceptance criteria

1. `swift test --filter "Tremolo|MSCXDiagnostics"` is 100% green.
2. `swift test` overall is 100% green (no regressions in the 12 MuseScore-equivalence cases or the other ~300 tests).
3. `swiftlint --quiet Sources Tests` reports zero warnings / errors.
4. A file with `<subtype>r128</subtype>` (or any other unknown tremolo subtype) loads via both `MSCXParser.parse(_:)` and `MSCXParser.parseWithDiagnostics(_:)`, with the latter returning exactly one warning whose `code == "mscx.tremolo.unknownSubtype"`.
5. A well-formed file (e.g. `midi01.mscx`) loads via `parseWithDiagnostics(_:)` with `diagnostics.isEmpty == true`.
6. `CLAUDE.md` is updated with the categorisation policy under "Permissive parser".
