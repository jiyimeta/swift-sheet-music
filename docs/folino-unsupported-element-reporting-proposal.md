# Folino Unsupported-Element Reporting — Root Cause and Proposal

**Status:** Proposal only. No Folino code is changed by this work.
**Audience:** Folino team — to act on after the swift-sheet-music dependency is bumped.

---

## 1. Root Cause (Confirmed)

Folino reports parse anomalies through a pipeline in
`Packages/Infrastructure/Sources/ScoreFiles/`:

```
LiveScoreFileGateway
  → MSCXParser.parseWithDiagnostics / MSCZReader.parseWithDiagnostics
  → ScoreDiagnosticReporter.report(_:)   ← filters to .warning only
  → FirebaseCrashReporter.record(error:) ← Crashlytics non-fatal
```

`ScoreDiagnosticReporter` (line 20) filters strictly:

```swift
where diagnostic.severity == .warning && seen.insert(diagnostic.code).inserted
```

The pipeline is correct. The gap was **upstream**: before this branch,
swift-sheet-music emitted `ScoreDiagnostic` warnings only for tremolo
subtypes, breath mark styles, and score-version mismatches. Notehead groups,
accidental subtypes, and vibrato variants that the renderer could not draw were
handled silently — the decoder accepted them, stored a raw token on the model
(e.g. `Note.headType = "xcircle"`), and the renderer fell back to a normal
notehead at draw time without emitting any diagnostic.

Concretely: a MuseScore 2 file with a "cross + circle" notehead (`<head>6</head>`,
token `xcircle`) parsed without error, stored the token, and Folino's parse-time
pipeline had nothing to forward to Crashlytics. The failure was invisible.

The root cause was in swift-sheet-music, not in Folino.

---

## 2. What This Branch Ships Upstream (the Real Fix)

`feature/notation-rendering-coverage` fixes the problem in two complementary
ways:

**a) Render the previously-unsupported elements.**
The renderer now handles all 35+ notehead groups (cross, diamond, xcircle, slash,
solfège shapes, Walker/Funk variants, …), all accidental subtypes (Gould arrow,
Stein-Zimmermann, AEU, Sagittal, microtonal families, …), and all vibrato line
variants. For scores that use these elements, Folino will now render them
correctly rather than falling back silently.

**b) Emit diagnostics for elements that still cannot be represented.**
For any `<head>`, `<subtype>` (accidental), or vibrato `<subtype>` that falls
outside the now-expanded known set, the decoder emits a `ScoreDiagnostic` with
`.warning` severity:

| Diagnostic code                   | Trigger                                              |
|-----------------------------------|------------------------------------------------------|
| `mscx.note.unsupportedHeadType`   | Unknown `<head>` integer (MS2) or token string (MS3/4) |
| `mscx.accidental.unsupportedSubtype` | Unknown accidental `<subtype>` string              |
| `mscx.vibrato.unknownSubtype`     | Unknown vibrato spanner `<subtype>` string           |

A bidirectional sync test (`Tests/SheetMusicTests/RenderCoverageSyncTests.swift`)
asserts that the decoder's "known" set equals the renderer's "renderable" set at
all times, so any future drift between parser and renderer is caught at CI.

---

## 3. Proposed Folino Change (One Step, Later)

After swift-sheet-music releases a tagged version that includes this branch,
the **only required action is a dependency bump** in Folino's
`Package.swift` (or whichever manifest pins swift-sheet-music):

```swift
// Before
.package(url: "…/swift-sheet-music", from: "x.y.z")

// After — bump to the version that ships feature/notation-rendering-coverage
.package(url: "…/swift-sheet-music", from: "x.y+1.0")
```

No Folino source change is needed. The three new diagnostic codes
(`mscx.note.unsupportedHeadType`, `mscx.accidental.unsupportedSubtype`,
`mscx.vibrato.unknownSubtype`) carry `.warning` severity and flow through
the existing `LiveScoreFileGateway → ScoreDiagnosticReporter → Crashlytics`
pipeline unchanged.

In Crashlytics, each code becomes a distinct non-fatal issue (the `NSError.domain`
is the code string — see `ScoreParseDiagnostic+NSError.swift` line 15) that
the team can group, alert on, and track without additional instrumentation.

---

## 4. Known Limitation Out of Scope

`LiveScoreFileGateway.loadScore` returns an empty diagnostic array for MusicXML,
MXL, and MIDI imports (lines 74–81 of `LiveScoreFileGateway.swift`):

```swift
case .musicXML:
    try (SheetMusic.loadScore(musicXMLData: data), [])
case .mxl:
    try (SheetMusic.loadScore(mxlData: data), [])
case .midi:
    try (SheetMusic.loadScore(midiData: data, …), [])
```

Unsupported elements in those formats are never reported, regardless of whether
swift-sheet-music's parsers for them emit diagnostics. Plumbing
`MusicXMLParser.parseWithDiagnostics` / MIDI equivalent into those branches
is a natural follow-up but is explicitly out of scope for this fix.

---

## 5. Summary

- This work (swift-sheet-music `feature/notation-rendering-coverage`) fixes the
  upstream cause: the renderer now covers the previously-unsupported elements,
  and the decoder emits `.warning` diagnostics for anything still outside the
  known set.
- Folino's existing pipeline requires **no code change** to benefit.
- The only action for the Folino team is to bump the swift-sheet-music
  dependency once a version carrying this branch is tagged and released.
- **No Folino code has been modified, staged, or committed as part of this work.**
