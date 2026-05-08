# Articulation Glyph Rendering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render staccato dot, staccatissimo wedge, and tenuto bar glyphs for chord-level articulations through the project's own layout / canvas / layer pipeline (so `SheetMusicUI` and `SheetMusicPDF` show what MuseScore already shows).

**Architecture:** The Layout layer emits a new `LayoutElement.articulation(kind, origin, isAbove)` for each in-scope `ChordArticulation`, immediately after the chord's main element. Placement resolves anchor/Y/stacking; YBounds and Translate gain mirroring `.fermata`-shaped cases. The renderer adds an `ArticulationRenderer` that maps `(kind, isAbove)` → SMuFL glyph and a parallel `drawArticulation` helper for the CALayer path. PDF reuses the same code paths automatically.

**Tech Stack:** Swift 5.9+, Swift Testing (`@Test`/`#expect`), CoreGraphics / CoreText / QuartzCore (CALayer), SMuFL (Bravura font).

Spec: `docs/superpowers/specs/2026-05-08-articulation-glyph-rendering-design.md`.

---

### Task 1: Extend `LayoutElement` with `ArticulationKind` + `.articulation` case

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutElement.swift`

Swift does not allow adding new cases via extension, so the new case and its nested enum must go inline in the existing `enum LayoutElement` body. Place the case alongside `.fermata`, and the nested enum near `TextMarkKind` / `SpannerKind`.

- [ ] **Step 1: Add the `.articulation` case next to `.fermata`**

In `LayoutElement.swift`, find the line:

```swift
    case fermata(subtype: String, origin: CGPoint)
```

Insert immediately after it:

```swift
    /// Per-chord articulation glyph (staccato dot / staccatissimo wedge /
    /// tenuto bar). Emitted from `placeMeasureElements` for each
    /// `ChordArticulation` whose `kind` is in scope; round-trip-only
    /// `.unknown(...)` entries are filtered out before reaching layout.
    /// `origin` is the SMuFL glyph anchor in measure-local coords;
    /// `isAbove` selects the above-vs-below glyph variant and is also
    /// used by the YBounds pass.
    case articulation(
        kind: ArticulationKind,
        origin: CGPoint,
        isAbove: Bool
    )
```

- [ ] **Step 2: Add the `ArticulationKind` nested enum**

Find the existing nested enums at the bottom of `LayoutElement`:

```swift
    public enum TextMarkKind: Sendable, Equatable {
```

Insert just before it:

```swift
    /// Layout-local subset of `ChordArticulation.Kind` containing only
    /// the renderable cases. The emitter filters `.unknown(...)` out
    /// before producing a `LayoutElement`, so the renderer's switch
    /// stays exhaustive without a `default` clause.
    public enum ArticulationKind: Sendable, Equatable {
        case staccato
        case staccatissimo
        case tenuto
    }

```

- [ ] **Step 3: Build to verify the enum compiles**

Run: `swift build`
Expected: succeeds (the case is unused so far; YBounds and Translate switches will fail compilation in later tasks if missed — that's by design).

If `swift build` reports a missing-case error in `LayoutEngine+YBounds.swift` or `LayoutEngine+Translate.swift`, that's the next task — proceed.

- [ ] **Step 4: Commit**

```bash
git add Sources/SheetMusicLayout/Layout/LayoutElement.swift
git commit -m "layout: add .articulation case and ArticulationKind to LayoutElement"
```

---

### Task 2: Handle `.articulation` in `elementYPoints`

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+YBounds.swift`

The skyline pass walks every `LayoutElement` to compute the staff's vertical reach. Treat the glyph as a thin point (the `glyphPad = sp` that wraps the result already covers the glyph's actual height).

- [ ] **Step 1: Add the `.articulation` case alongside `.fermata` in the first switch**

In `elementYPoints(_:)`, find:

```swift
        case let .clef(_, p),
             let .keySignature(_, _, p),
             let .timeSignature(_, _, p),
             let .barLine(_, p),
             let .textMark(_, _, p),
             let .fermata(_, p),
             let .marker(_, _, p),
             let .jump(_, p),
             let .measureRepeat(_, p),
             let .measureNumber(_, p),
             let .staffName(_, p),
             let .staffText(_, p, _, _),
             let .rehearsalMark(_, p, _, _):
            return [p.y]
```

Add `.articulation` to the alternation. Replace the block with:

```swift
        case let .clef(_, p),
             let .keySignature(_, _, p),
             let .timeSignature(_, _, p),
             let .barLine(_, p),
             let .textMark(_, _, p),
             let .fermata(_, p),
             let .articulation(_, p, _),
             let .marker(_, _, p),
             let .jump(_, p),
             let .measureRepeat(_, p),
             let .measureNumber(_, p),
             let .staffName(_, p),
             let .staffText(_, p, _, _),
             let .rehearsalMark(_, p, _, _):
            return [p.y]
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: still fails on `LayoutEngine+Translate.swift` (next task) unless that's already done. The YBounds switch should now compile cleanly.

- [ ] **Step 3: Commit**

```bash
git add Sources/SheetMusicLayout/Layout/LayoutEngine+YBounds.swift
git commit -m "layout: include .articulation in elementYPoints skyline"
```

---

### Task 3: Handle `.articulation` in `translate(element:dy:)`

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Translate.swift`

Per-staff vertical translate for system stacking. Mirror `.fermata`.

- [ ] **Step 1: Add the `.articulation` case after the `.fermata` case**

Find:

```swift
        case let .fermata(s, p):
            return .fermata(subtype: s, origin: shift(p))
```

Insert immediately after:

```swift
        case let .articulation(kind, p, isAbove):
            return .articulation(
                kind: kind,
                origin: shift(p),
                isAbove: isAbove
            )
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: succeeds. All exhaustive switches now cover `.articulation`.

- [ ] **Step 3: Run the existing tests to confirm no regressions**

Run: `swift test`
Expected: all green. No test exercises the new case yet, but every layout-touching test must keep passing now that switches handle `.articulation`.

- [ ] **Step 4: Commit**

```bash
git add Sources/SheetMusicLayout/Layout/LayoutEngine+Translate.swift
git commit -m "layout: shift .articulation origin in per-staff translate"
```

---

### Task 4: Add the six SMuFL glyph entries

**Files:**
- Modify: `Sources/SheetMusicUI/Rendering/SMuFLGlyph.swift`

Add the six articulation codepoints. The file's other glyph blocks are organised by SMuFL range; place the new block just below the fermata entries (range U+E4A0..U+E4FF — Articulations / Holds and Pauses both live here).

- [ ] **Step 1: Add the articulation block after the fermata entries**

Find:

```swift
    static let fermataAbove: Character = "\u{E4C0}"
    static let fermataBelow: Character = "\u{E4C1}"
```

Insert immediately after (and before the next `// Bracket caps + brace variants.` comment):

```swift

    // Articulations — SMuFL Articulation range (U+E4A0..U+E4BF).
    // Above/below pairs render the same shape mirrored across the
    // baseline; MuseScore picks the variant from the articulation's
    // resolved anchor side. Codepoints from SMuFL `glyphnames.json`.
    static let articStaccatoAbove: Character = "\u{E4A2}"
    static let articStaccatoBelow: Character = "\u{E4A3}"
    static let articTenutoAbove: Character = "\u{E4A4}"
    static let articTenutoBelow: Character = "\u{E4A5}"
    static let articStaccatissimoAbove: Character = "\u{E4A6}"
    static let articStaccatissimoBelow: Character = "\u{E4A7}"
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 3: Commit**

```bash
git add Sources/SheetMusicUI/Rendering/SMuFLGlyph.swift
git commit -m "ui: add SMuFL codepoints for staccato/staccatissimo/tenuto"
```

---

### Task 5: Implement articulation emission in `placeMeasureElements`

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift`

Right after the chord's `mainElement` is appended (and before the grace-notes-after / arpeggio block? — no, we must place AFTER all `voiceChordOutIndex` indexing is set, so that beam-rewrite later still finds the chord; see Step 1 for the exact site). The simplest correct site is **immediately after the `out.append(mainElement)` line** but BEFORE the `for (gIdx, g) in chord.graceNotesAfter`. At that point `voiceChordOutIndex[voiceElemIdx] = out.count` was assigned the index of `mainElement` (one less than `out.count` after the append), so we don't disturb it.

- [ ] **Step 1: Verify the insertion site**

Run: `grep -n "voiceChordOutIndex\[voiceElemIdx\] = out.count\|out.append(mainElement)\|chord.graceNotesAfter" Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift`

Expected output (line numbers may differ slightly):

```
538:                    voiceChordOutIndex[voiceElemIdx] = out.count
539:                    out.append(mainElement)
540:                    for (gIdx, g) in chord.graceNotesAfter.enumerated() {
```

The new emit block goes between line 539 (the `mainElement` append) and line 540 (the after-grace loop). It does not append into `voiceChordOutIndex` — articulations don't participate in beaming.

- [ ] **Step 2: Add the helper `renderableArticulationKind(_:)` at the bottom of the extension**

`LayoutEngine+Placement.swift` ends at the closing brace of `extension LayoutEngine`. Inside that extension, add the helper at the bottom of the type (just before the final closing `}` of the extension):

Find the last function in the extension — `makeGraceLayoutNotes` — and locate its closing `}` followed by `// swiftlint:enable function_parameter_count`. Insert the helper after the swiftlint enable directive but before the extension's closing `}`:

```swift

    /// Map a `ChordArticulation.Kind` to the renderable layout-local
    /// kind, returning `nil` for `.unknown(_)` so callers skip emission.
    static func renderableArticulationKind(
        _ kind: ChordArticulation.Kind
    ) -> LayoutElement.ArticulationKind? {
        switch kind {
        case .staccato:      return .staccato
        case .staccatissimo: return .staccatissimo
        case .tenuto:        return .tenuto
        case .unknown:       return nil
        }
    }
```

- [ ] **Step 3: Add the per-chord articulation emit block**

Inside `case let .chord(chord):` in `placeMeasureElements`, find:

```swift
                    voiceChordOutIndex[voiceElemIdx] = out.count
                    out.append(mainElement)
                    for (gIdx, g) in chord.graceNotesAfter.enumerated() {
```

Replace with:

```swift
                    voiceChordOutIndex[voiceElemIdx] = out.count
                    out.append(mainElement)
                    // Chord-level articulation glyphs (staccato / staccatissimo /
                    // tenuto). Round-trip-only `.unknown` kinds are filtered.
                    // Anchor: explicit `art.anchor` wins; `nil` falls back to
                    // Gould's opposite-side rule (stem-up → below).
                    // Stacking: each additional glyph on the same side adds
                    // 1 sp away from the staff. Outside-staff push: if the
                    // base Y lands inside the staff, clamp it past the
                    // nearest staff edge by 0.5 sp.
                    let staffTopY = staffMidY - metrics.sp * 2
                    let staffBottomY = staffMidY + metrics.sp * 2
                    var aboveCount = 0
                    var belowCount = 0
                    for art in chord.articulations {
                        guard let artKind = renderableArticulationKind(art.kind)
                        else { continue }
                        let isAbove: Bool
                        switch art.anchor {
                        case .above: isAbove = true
                        case .below: isAbove = false
                        case nil:    isAbove = (stem == .down)
                        }
                        let noteYs = chordNotes.map(\.origin.y)
                        let baseY: CGFloat
                        if isAbove {
                            baseY = (noteYs.min() ?? staffMidY) - metrics.sp * 0.5
                        } else {
                            baseY = (noteYs.max() ?? staffMidY) + metrics.sp * 0.5
                        }
                        let pushed: CGFloat
                        if isAbove {
                            pushed = min(baseY, staffTopY - metrics.sp * 0.5)
                        } else {
                            pushed = max(baseY, staffBottomY + metrics.sp * 0.5)
                        }
                        let stackUnits = isAbove ? aboveCount : belowCount
                        let stackOffset = metrics.sp * CGFloat(stackUnits)
                        let y = pushed + (isAbove ? -stackOffset : stackOffset)
                        out.append(.articulation(
                            kind: artKind,
                            origin: CGPoint(x: chordX, y: y),
                            isAbove: isAbove
                        ))
                        if isAbove { aboveCount += 1 } else { belowCount += 1 }
                    }
                    for (gIdx, g) in chord.graceNotesAfter.enumerated() {
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 5: Run the full suite to confirm no regressions in other layout tests**

Run: `swift test`
Expected: all green. Existing tests use chords without articulations, so the new emit block runs zero iterations and the output is bit-identical for them.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift
git commit -m "layout: emit .articulation per chord (anchor, push, stacking)"
```

---

### Task 6: Add `ArticulationRenderer` and wire `ScoreCanvas`

**Files:**
- Create: `Sources/SheetMusicUI/Rendering/ArticulationRenderer.swift`
- Modify: `Sources/SheetMusicUI/Rendering/ScoreCanvas.swift`

- [ ] **Step 1: Create the renderer**

Write `Sources/SheetMusicUI/Rendering/ArticulationRenderer.swift`:

```swift
import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, iOS 16.0, *)
enum ArticulationRenderer {
    /// Draw one articulation glyph at `origin` using the SMuFL
    /// codepoint that matches `(kind, isAbove)`. The glyph anchor
    /// matches Bravura's metrics: U+E4A2/E4A4/E4A6 sit just below
    /// their baseline (above variants) and U+E4A3/E4A5/E4A7 sit just
    /// above (below variants), so the same `origin` works for both.
    static func draw(
        context: inout GraphicsContext,
        kind: LayoutElement.ArticulationKind,
        isAbove: Bool,
        origin: CGPoint,
        metrics: StaffMetrics
    ) {
        let glyph: Character
        switch (kind, isAbove) {
        case (.staccato, true):       glyph = SMuFLGlyph.articStaccatoAbove
        case (.staccato, false):      glyph = SMuFLGlyph.articStaccatoBelow
        case (.staccatissimo, true):  glyph = SMuFLGlyph.articStaccatissimoAbove
        case (.staccatissimo, false): glyph = SMuFLGlyph.articStaccatissimoBelow
        case (.tenuto, true):         glyph = SMuFLGlyph.articTenutoAbove
        case (.tenuto, false):        glyph = SMuFLGlyph.articTenutoBelow
        }
        context.drawGlyph(
            glyph, at: origin, size: metrics.glyphFontSize
        )
    }
}
```

- [ ] **Step 2: Wire into `ScoreCanvas` next to the `.fermata` case**

In `Sources/SheetMusicUI/Rendering/ScoreCanvas.swift`, find:

```swift
        case let .fermata(subtype, p):
            FermataRenderer.draw(
                context: &context, subtype: subtype,
                origin: shift(p), metrics: metrics
            )
```

Insert immediately after:

```swift
        case let .articulation(kind, p, isAbove):
            ArticulationRenderer.draw(
                context: &context, kind: kind,
                isAbove: isAbove, origin: shift(p),
                metrics: metrics
            )
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: succeeds. `ScoreLayerBuilder+Element.swift` will now warn (or error) about a missing case — addressed in Task 7.

- [ ] **Step 4: Commit**

```bash
git add Sources/SheetMusicUI/Rendering/ArticulationRenderer.swift Sources/SheetMusicUI/Rendering/ScoreCanvas.swift
git commit -m "ui: ArticulationRenderer + ScoreCanvas wiring for .articulation"
```

---

### Task 7: Wire `ScoreLayerBuilder` (CALayer path)

**Files:**
- Modify: `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Misc.swift`
- Modify: `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Element.swift`

- [ ] **Step 1: Add `drawArticulation` helper next to `drawFermata`**

In `Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Misc.swift`, find:

```swift
    static func drawFermata(
        subtype: String, origin: CGPoint,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
    ) {
        let below = subtype.hasPrefix("fermataBelow")
        let glyph = below
            ? SMuFLGlyph.fermataBelow
            : SMuFLGlyph.fermataAbove
        if let layer = glyphLayer(
            glyph, at: origin,
            size: metrics.glyphFontSize,
            height: height
        ) {
            parent.addSublayer(layer)
        }
    }
```

Insert immediately after the closing `}` (and before `// MARK: - Measure repeat`):

```swift

    // MARK: - Articulation

    static func drawArticulation(
        kind: LayoutElement.ArticulationKind,
        isAbove: Bool,
        origin: CGPoint,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
    ) {
        let glyph: Character
        switch (kind, isAbove) {
        case (.staccato, true):       glyph = SMuFLGlyph.articStaccatoAbove
        case (.staccato, false):      glyph = SMuFLGlyph.articStaccatoBelow
        case (.staccatissimo, true):  glyph = SMuFLGlyph.articStaccatissimoAbove
        case (.staccatissimo, false): glyph = SMuFLGlyph.articStaccatissimoBelow
        case (.tenuto, true):         glyph = SMuFLGlyph.articTenutoAbove
        case (.tenuto, false):        glyph = SMuFLGlyph.articTenutoBelow
        }
        if let layer = glyphLayer(
            glyph, at: origin,
            size: metrics.glyphFontSize,
            height: height
        ) {
            parent.addSublayer(layer)
        }
    }
```

- [ ] **Step 2: Wire into `ScoreLayerBuilder+Element.swift` next to the `.fermata` case**

Find:

```swift
        case let .fermata(subtype, p):
            drawFermata(
                subtype: subtype, origin: shift(p),
                metrics: metrics, height: height, into: parent
            )
```

Insert immediately after:

```swift
        case let .articulation(kind, p, isAbove):
            drawArticulation(
                kind: kind, isAbove: isAbove,
                origin: shift(p),
                metrics: metrics, height: height, into: parent
            )
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: succeeds.

- [ ] **Step 4: Run the full test suite**

Run: `swift test`
Expected: all green; no behavioural changes for chords without articulations.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Misc.swift Sources/SheetMusicUI/Rendering/ScoreLayerBuilder+Element.swift
git commit -m "ui: drawArticulation CALayer helper + element switch wiring"
```

---

### Task 8: Layout placement tests

**Files:**
- Create: `Tests/SheetMusicTests/LayoutArticulationTests.swift`

Build small Scores programmatically and assert on the `[LayoutElement]` produced by `LayoutEngine.layout(...)`. Pattern mirrors `LayoutCacheTests` and `ScoreLayerBuilderTests`. Layout returns elements already translated into document coords; for a single-staff score the staff Y offset is constant, so we extract it from the score's first chord (its origin Y is the chord's notehead Y in document coords) rather than recomputing it independently.

- [ ] **Step 1: Write the test file with helpers and the explicit-anchor cases**

Create `Tests/SheetMusicTests/LayoutArticulationTests.swift`:

```swift
import CoreGraphics
import SheetMusicCore
@testable import SheetMusicLayout
import Testing

@Suite("LayoutEngine articulation emission")
@available(macOS 15.0, iOS 16.0, *)
struct LayoutArticulationTests {
    /// Build a one-measure score whose single chord has `articulations`.
    /// `pitch` controls staff position (60 = middle C, treble; 71 = B
    /// just above the middle line).
    private static func score(
        pitch: Int = 60,
        articulations: [ChordArticulation] = []
    ) -> Score {
        let note = Note(pitch: pitch, tpc: 14)
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([note]),
            articulations: articulations
        )
        let measure = Measure(voices: [Voice(elements: [.chord(chord)])])
        let staff = Staff(measures: [measure])
        return Score(
            division: 480,
            parts: [Part(
                id: "1",
                instrument: Instrument(id: "x"),
                staves: [staff]
            )]
        )
    }

    private static func laidOut(_ s: Score) -> LayoutDocument {
        let opts = ScoreViewOptions(
            staffSize: 28, systemGap: 40, wrapToViewWidth: false
        )
        let natW = LayoutEngine.naturalContentWidth(score: s, options: opts)
        return LayoutEngine.layout(
            score: s, options: opts, availableWidth: natW
        )
    }

    /// Pull the single articulation + chord from a single-measure
    /// single-staff document. Returns `nil` if not exactly one of each.
    private static func soleArtAndChord(
        _ doc: LayoutDocument
    ) -> (LayoutElement, LayoutElement)? {
        guard let measure = doc.systems.first?.measures.first
        else { return nil }
        var art: LayoutElement?
        var chord: LayoutElement?
        for el in measure.elements {
            if case .articulation = el {
                if art != nil { return nil }
                art = el
            }
            if case .chord = el {
                if chord != nil { return nil }
                chord = el
            }
        }
        guard let a = art, let c = chord else { return nil }
        return (a, c)
    }

    @Test("Explicit above anchor emits one .articulation with isAbove=true")
    func explicitAboveAnchor() throws {
        let doc = Self.laidOut(Self.score(
            articulations: [.init(kind: .staccato, anchor: .above)]
        ))
        let (art, chord) = try #require(Self.soleArtAndChord(doc))
        guard case let .articulation(kind, origin, isAbove) = art
        else { Issue.record("not articulation"); return }
        guard case let .chord(notes, _, _, _, _, _, _, _) = chord
        else { Issue.record("not chord"); return }
        #expect(kind == .staccato)
        #expect(isAbove == true)
        // Above placement: Y is 0.5 sp above the highest notehead Y
        // (single-note chord → that note's Y). Outside-staff push may
        // adjust further; for pitch 60 in treble the note sits below
        // the staff bottom so the base Y starts just above it and is
        // pushed past `staffTopY - 0.5 sp`. We assert `articY ≤ noteY
        // - 0.5 sp` rather than equality.
        let noteY = try #require(notes.first?.origin.y)
        #expect(origin.y <= noteY - doc.metrics.sp * 0.5 + 0.001)
    }

    @Test("Explicit below anchor emits isAbove=false")
    func explicitBelowAnchor() throws {
        let doc = Self.laidOut(Self.score(
            articulations: [.init(kind: .staccato, anchor: .below)]
        ))
        let (art, chord) = try #require(Self.soleArtAndChord(doc))
        guard case let .articulation(_, origin, isAbove) = art
        else { Issue.record("not articulation"); return }
        guard case let .chord(notes, _, _, _, _, _, _, _) = chord
        else { Issue.record("not chord"); return }
        #expect(isAbove == false)
        let noteY = try #require(notes.first?.origin.y)
        #expect(origin.y >= noteY + doc.metrics.sp * 0.5 - 0.001)
    }
}
```

- [ ] **Step 2: Run the file's tests and confirm they pass**

Run: `swift test --filter LayoutArticulationTests`
Expected: 2 passing tests.

- [ ] **Step 3: Add the auto-anchor (Gould's rule) cases**

Append two new `@Test` methods inside `LayoutArticulationTests`, before the final closing brace:

```swift
    @Test("Auto anchor on stem-up chord lands below (opposite-side rule)")
    func autoAnchorStemUp() throws {
        // Pitch 60 (middle C in treble) is below the middle line, so
        // `StemDirectionRule` picks stem-up. Auto anchor is opposite of
        // stem → below.
        let doc = Self.laidOut(Self.score(
            pitch: 60,
            articulations: [.init(kind: .staccato, anchor: nil)]
        ))
        let (art, _) = try #require(Self.soleArtAndChord(doc))
        guard case let .articulation(_, _, isAbove) = art
        else { Issue.record("not articulation"); return }
        #expect(isAbove == false)
    }

    @Test("Auto anchor on stem-down chord lands above")
    func autoAnchorStemDown() throws {
        // Pitch 79 (G5 in treble) sits well above the middle line, so
        // the chord stems down. Auto anchor → above.
        let doc = Self.laidOut(Self.score(
            pitch: 79,
            articulations: [.init(kind: .staccato, anchor: nil)]
        ))
        let (art, _) = try #require(Self.soleArtAndChord(doc))
        guard case let .articulation(_, _, isAbove) = art
        else { Issue.record("not articulation"); return }
        #expect(isAbove == true)
    }
```

- [ ] **Step 4: Run the new cases**

Run: `swift test --filter LayoutArticulationTests`
Expected: 4 passing tests.

- [ ] **Step 5: Add the outside-staff push cases**

Append two more `@Test` methods, before the final closing brace:

```swift
    @Test("Above placement pushes past the top staff line")
    func outsideStaffPushAbove() throws {
        // Pitch 71 (B4) sits on the middle line in treble. Naive Y
        // (`noteY - 0.5 sp`) lands inside the staff, so the push must
        // clamp it to `staffTopY - 0.5 sp` or higher (smaller Y).
        let doc = Self.laidOut(Self.score(
            pitch: 71,
            articulations: [.init(kind: .staccato, anchor: .above)]
        ))
        let (art, _) = try #require(Self.soleArtAndChord(doc))
        guard case let .articulation(_, origin, _) = art
        else { Issue.record("not articulation"); return }
        // staffMidY equals `staffHeight/2 + sp*2` in measure-local
        // coords, but doc-coords add the system origin. We compute
        // the staff top relative to the chord's notehead at step 0
        // (B4 in treble → step 4 in MuseScore staff steps; treble
        // mapping in PitchStaffPosition puts B4 at step 6 above
        // middle C — the relative Y deltas remain stable).
        // Simplest invariant: articulation Y must be at most
        // `staffTopY - 0.5 sp`, where staffTopY is 2 sp above the
        // staff midline. Recover staffMidY from the document's first
        // measure origin + per-staff offset.
        guard let system = doc.systems.first,
              let staffOriginY = system.staffOrigins.first
        else { Issue.record("no staff origin"); return }
        let sp = doc.metrics.sp
        let staffMidY = staffOriginY + doc.metrics.staffHeight / 2
        let staffTopY = staffMidY - sp * 2
        #expect(origin.y <= staffTopY - sp * 0.5 + 0.001)
    }

    @Test("Below placement pushes past the bottom staff line")
    func outsideStaffPushBelow() throws {
        let doc = Self.laidOut(Self.score(
            pitch: 71,
            articulations: [.init(kind: .staccato, anchor: .below)]
        ))
        let (art, _) = try #require(Self.soleArtAndChord(doc))
        guard case let .articulation(_, origin, _) = art
        else { Issue.record("not articulation"); return }
        guard let system = doc.systems.first,
              let staffOriginY = system.staffOrigins.first
        else { Issue.record("no staff origin"); return }
        let sp = doc.metrics.sp
        let staffMidY = staffOriginY + doc.metrics.staffHeight / 2
        let staffBottomY = staffMidY + sp * 2
        #expect(origin.y >= staffBottomY + sp * 0.5 - 0.001)
    }
```

- [ ] **Step 6: Run the new cases**

Run: `swift test --filter LayoutArticulationTests`
Expected: 6 passing tests. If `system.staffOrigins` doesn't exist or has a different name, fall back to comparing against the chord's notehead Y plus `staffHeight / 2 - sp * 1.5` (i.e. measure 2 sp above the lowest note for a single-line score) — but `staffOrigins` is the documented public surface, so prefer it.

- [ ] **Step 7: Add stacking, unknown, and kind-mapping cases**

Append three more `@Test` methods, before the final closing brace:

```swift
    @Test("Two above-anchored articulations stack 1 sp apart")
    func stacking() throws {
        let doc = Self.laidOut(Self.score(
            articulations: [
                .init(kind: .staccato, anchor: .above),
                .init(kind: .tenuto, anchor: .above),
            ]
        ))
        guard let measure = doc.systems.first?.measures.first
        else { Issue.record("no measure"); return }
        let arts = measure.elements.compactMap { el -> CGFloat? in
            if case let .articulation(_, p, _) = el { return p.y }
            return nil
        }
        #expect(arts.count == 2)
        try #require(arts.count == 2)
        // Source order is innermost-first: arts[0] is the staccato
        // (closer to the staff), arts[1] is the tenuto stacked one
        // sp further above (smaller Y).
        let delta = arts[0] - arts[1]
        #expect(abs(delta - doc.metrics.sp) < 0.001)
    }

    @Test("Unknown articulation kind emits no .articulation element")
    func unknownIsFiltered() throws {
        let doc = Self.laidOut(Self.score(
            articulations: [
                .init(kind: .unknown(subtype: "articAccentAbove"),
                      anchor: .above),
            ]
        ))
        guard let measure = doc.systems.first?.measures.first
        else { Issue.record("no measure"); return }
        let count = measure.elements.reduce(into: 0) { acc, el in
            if case .articulation = el { acc += 1 }
        }
        #expect(count == 0)
    }

    @Test("Kind mapping covers staccatissimo and tenuto")
    func kindMapping() throws {
        for (input, expected) in [
            (ChordArticulation.Kind.staccatissimo,
             LayoutElement.ArticulationKind.staccatissimo),
            (.tenuto, .tenuto),
        ] {
            let doc = Self.laidOut(Self.score(
                articulations: [.init(kind: input, anchor: .above)]
            ))
            let (art, _) = try #require(Self.soleArtAndChord(doc))
            guard case let .articulation(kind, _, _) = art
            else { Issue.record("not articulation"); return }
            #expect(kind == expected)
        }
    }
```

- [ ] **Step 8: Run the full file's tests**

Run: `swift test --filter LayoutArticulationTests`
Expected: 9 passing tests.

- [ ] **Step 9: Run the full project test suite to confirm no regressions**

Run: `swift test`
Expected: all green.

- [ ] **Step 10: Commit**

```bash
git add Tests/SheetMusicTests/LayoutArticulationTests.swift
git commit -m "test: cover articulation emission, anchor, push, stacking"
```

---

### Task 9: Renderer-side smoke test (CALayer pipeline)

**Files:**
- Modify: `Tests/SheetMusicTests/ScoreLayerBuilderTests.swift`

A single test case proves the full path: `Chord.articulations` → `LayoutEngine` → `ScoreLayerBuilder.buildSystem` → CALayer with a glyph sublayer at the articulation's Y. The pattern mirrors the existing `acciaccaturaSlashIsDrawn` test.

- [ ] **Step 1: Add a new `@Test` method to `ScoreLayerBuilderTests`**

In `Tests/SheetMusicTests/ScoreLayerBuilderTests.swift`, find the closing of `acciaccaturaSlashIsDrawn`:

```swift
            #expect(
                diagonal != nil,
                "no diagonal stroke layer found among \(strokes.count) strokes"
            )
        }
    }
#endif
```

Insert a new test method before the final `}` of the struct:

```swift
        @MainActor
        @Test("Staccato chord emits a glyph sublayer above the staff")
        func staccatoEmitsGlyphLayer() throws {
            guard #available(macOS 15.0, *) else { return }
            _ = BravuraFont.register
            let chord = Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
                articulations: [
                    .init(kind: .staccato, anchor: .above),
                ]
            )
            let staff = Staff(measures: [
                Measure(voices: [Voice(elements: [.chord(chord)])]),
            ])
            let score = Score(division: 480, parts: [
                Part(
                    id: "1",
                    instrument: Instrument(id: "x"),
                    staves: [staff]
                ),
            ])
            let opts = ScoreViewOptions(
                staffSize: 28, systemGap: 40, wrapToViewWidth: false
            )
            let natW = LayoutEngine.naturalContentWidth(
                score: score, options: opts
            )
            let doc = LayoutEngine.layout(
                score: score, options: opts, availableWidth: natW
            )
            let system = try #require(doc.systems.first)
            let tree = ScoreLayerBuilder.buildSystem(
                system, metrics: doc.metrics
            )
            // The articulation is emitted as a CAShapeLayer with a
            // small filled glyph path (≈ 1 sp wide, < 1 sp tall),
            // distinct from noteheads (~ 1.2 sp wide and tall) and
            // accidentals (taller).
            let sp = doc.metrics.sp
            let glyphLayers = collectAllLayers(tree)
                .compactMap { $0 as? CAShapeLayer }
                .filter { $0.fillColor != nil && $0.path != nil }
            // Find a layer whose bbox is small enough to be the
            // staccato dot — width and height both < sp * 1.0.
            let dot = glyphLayers.first { l in
                guard let p = l.path else { return false }
                let bb = p.boundingBoxOfPath
                return bb.width > 0 && bb.width < sp
                    && bb.height > 0 && bb.height < sp
            }
            #expect(
                dot != nil,
                "no staccato-sized glyph layer found among \(glyphLayers.count) filled layers"
            )
        }
```

- [ ] **Step 2: Run the new test**

Run: `swift test --filter ScoreLayerBuilderTests/staccatoEmitsGlyphLayer`
Expected: passes. If the bbox heuristic is too tight (the staccato dot is small but Bravura's actual glyph metrics may put it slightly larger than `sp * 1`), loosen the upper bound to `sp * 1.2` and rerun.

- [ ] **Step 3: Run the full suite**

Run: `swift test`
Expected: all green.

- [ ] **Step 4: Commit**

```bash
git add Tests/SheetMusicTests/ScoreLayerBuilderTests.swift
git commit -m "test: smoke test staccato glyph appears in CALayer pipeline"
```

---

### Task 10: Lint and final verification

**Files:** none (verification only)

- [ ] **Step 1: Run the linter**

Run: `swiftlint --quiet Sources Tests`
Expected: 0 warnings/errors. If `LayoutEngine+Placement.swift` trips the `function_body_length` cap (it already has `swiftlint:disable function_body_length file_length` at the top, so it shouldn't), no action needed. If a new file trips a rule, fix the formatting in place rather than adding a disable comment.

- [ ] **Step 2: Run the full test suite one more time**

Run: `swift test`
Expected: all green; total test count is 9 higher than before (8 in `LayoutArticulationTests` + 1 in `ScoreLayerBuilderTests`).

- [ ] **Step 3: Visual verification (manual — out of CI)**

The user should run `SheetMusicExampleMac` against an `.mscx` containing a chord with `<Articulation><subtype>articStaccatoAbove</subtype></Articulation>` and confirm the dot appears at the expected place. Per project memory `feedback_visual_verify_mac.md`, visual verification uses the Mac example app — not the iOS simulator. Do not block this task on the result; report and let the user decide.

- [ ] **Step 4: Final commit (only if there are uncommitted lint fixes)**

If Step 1 produced any in-place fixes:

```bash
git add -u
git commit -m "style: address swiftlint findings for articulation files"
```

Otherwise, no commit.

---

## Self-review

**Spec coverage:**
- Architecture / file-by-file diff: Tasks 1–7 cover every file the spec listed.
- LayoutElement extension: Task 1.
- Emission rules (filter, anchor resolve, Y origin, push, stacking, X origin): Task 5, with `renderableArticulationKind` helper covering filter, `art.anchor` switch covering anchor resolve, the `baseY` block covering Y origin, the `pushed` block covering push, the `stackUnits` block covering stacking, and `chordX` covering X origin.
- YBounds extension: Task 2.
- Translate extension: Task 3.
- Renderer (new file + ScoreCanvas + ScoreLayerBuilder): Tasks 6 and 7.
- SMuFL glyph mapping: Task 4.
- Programmatic tests #1–9 in spec: Task 8 implements all 9 (renamed slightly for readability — explicit above/below, auto stem-up/down, push above/below, stacking, unknown filtered, kind mapping for staccatissimo+tenuto).
- Renderer-side smoke test: Task 9.
- Visual verification: Task 10 Step 3.

**Placeholder scan:** No "TBD" / "TODO" / "implement later" in any task. Every code step contains the actual code. Every command step shows the command and the expected outcome.

**Type consistency:** `ArticulationKind` cases (`.staccato`/`.staccatissimo`/`.tenuto`) and `LayoutElement.articulation(kind:origin:isAbove:)` signature match across Tasks 1, 2, 3, 5, 6, 7. SMuFL static-let names (`articStaccatoAbove`, etc.) match between Task 4 and Tasks 6/7. `renderableArticulationKind` is defined in Task 5 Step 2 and called in Task 5 Step 3.

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-08-articulation-glyph-rendering.md`. Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
