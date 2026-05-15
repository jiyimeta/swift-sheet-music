# Typed-Whole Rest Positioning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** In the layout engine, position rests at their start-beat tick — centring only `.measure` markers in the bar's chord area. Typed `.whole` rests sit on tick 0 (or wherever their start beat falls in irregular meters), matching MuseScore's data model.

**Architecture:** Single predicate change in `LayoutEngine+Placement.swift` — replace `let isWholeRest = restBase == .whole` with a `.measure`-only check. The `restY` switch and the leger-line predicate keep using `restBase`. Add one regression test for typed `.whole`/`.half` positioning in 6/4; migrate one existing fixture (`MultiStaffAlignmentTests` voice-1 rest) from `.whole` to `.measure` so its centring assertion still holds.

**Tech Stack:** Swift 5.9+, Swift Testing (`@Test` / `#expect`), SPM. Layout in `SheetMusicLayout`.

Spec: `docs/superpowers/specs/2026-05-15-typed-whole-rest-positioning-design.md`.

---

## File Structure

**Modified:**
- `Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift` — change the rest-X predicate around lines 500–517.
- `Tests/SheetMusicTests/MultiStaffAlignmentTests.swift` — migrate the voice-1 rest fixture at line 200 from `.whole` to `.measure`.

**Created:**
- `Tests/SheetMusicTests/TypedRestPositioningTests.swift` — new regression suite for the start-beat positioning rule (and a paired control for the `.measure`-centring rule).

**Untouched but worth knowing:**
- `Tests/SheetMusicTests/LayoutCacheTests.swift:21`, `EffectiveMeasureDurationsTests.swift:14`, `MultiMeasureRestPlannerTests.swift:128/146`, `ScoreActiveKeyTests.swift:20` all author `.rest(duration: .whole)` but none of them assert the rest's X. Their `.whole` rests will visually move from the bar centre to tick 0 after this change but no assertion fails. Leaving them as `.whole` is correct.
- `Sources/RenderPreviews/Samples.swift` (lines 216, 564, 1044) — preview fixtures for visual inspection. Not under test. The visual will change (rest at tick 0 rather than centred). Out of scope for this plan; the visual is correct under the new rule.

---

## Task 1: Migrate the `MultiStaffAlignmentTests` voice-1 fixture and tighten the predicate

**Why one commit:** The predicate change makes the existing
`multiVoiceWholeRestCentersInMeasure` test fail (because its
`.rest(duration: .whole)` no longer centres). Migrating the fixture
and changing the predicate must land together so the suite stays
green at every commit boundary.

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift` (lines ~500–517)
- Modify: `Tests/SheetMusicTests/MultiStaffAlignmentTests.swift` (line 200)
- Create: `Tests/SheetMusicTests/TypedRestPositioningTests.swift`

- [ ] **Step 1: Write the new failing tests for typed-whole positioning + `.measure` control**

Create `Tests/SheetMusicTests/TypedRestPositioningTests.swift`:

```swift
import SheetMusicCore
@testable import SheetMusicLayout
import Testing
import CoreGraphics

@available(macOS 15.0, iOS 16.0, *)
@Suite("TypedRestPositioning")
struct TypedRestPositioningTests {
    private static func makeScore(elements: [VoiceElement]) -> Score {
        let m = Measure(voices: [Voice(elements: elements)])
        return Score(
            division: 480,
            parts: [Part(
                id: "P1",
                instrument: Instrument(id: "pno"),
                staves: [Staff(measures: [m])],
            )],
            systemMeasures: [SystemMeasure()],
        )
    }

    private static func restOrigins(
        in score: Score, availableWidth: CGFloat = 900,
    ) -> [CGFloat] {
        let doc = LayoutEngine.layout(
            score: score,
            options: .init(wrapToViewWidth: false),
            availableWidth: availableWidth,
        )
        guard let measure = doc.systems.first?.measures.first else {
            return []
        }
        var xs: [CGFloat] = []
        for emitted in measure.emissions {
            if case let .rest(_, origin, _, _, _) = emitted {
                xs.append(origin.x)
            }
        }
        return xs
    }

    @Test("6/4 whole+half: whole at beat 1, half at beat 5")
    func sixFourTypedRestsHitTheirStartBeats() {
        let score = Self.makeScore(elements: [
            .clef(Clef(concertClefType: "G")),
            .timeSignature(TimeSignature(numerator: 6, denominator: 4)),
            .rest(duration: .whole),
            .rest(duration: .half),
        ])
        let xs = Self.restOrigins(in: score)
        #expect(xs.count == 2)
        #expect(xs[0] < xs[1], "whole rest must precede the half rest in X")
    }

    @Test(".measure rest still centres in the bar's chord area")
    func measureRestStillCenters() {
        let score = Self.makeScore(elements: [
            .clef(Clef(concertClefType: "G")),
            .timeSignature(TimeSignature(numerator: 6, denominator: 4)),
            .rest(duration: .measure),
        ])
        let xs = Self.restOrigins(in: score)
        #expect(xs.count == 1)
        // The single .measure rest must NOT sit at tick 0. With the
        // earlier-emitted clef + time signature occupying the header,
        // tick-0 sits at `headerSchedule.contentStartX`, well to the
        // left of the bar mid-point. The exact X is fragile against
        // spacing tuning so we only assert "comfortably right of the
        // header" — i.e., at least 80pt past the leftmost emitted
        // element.
        let leftmostHeader = xs[0]
        let oneSpace: CGFloat = 80
        #expect(leftmostHeader > oneSpace,
                "centred .measure rest x=\(leftmostHeader) should be well right of the header")
    }
}
```

- [ ] **Step 2: Run the new tests — expect both to fail**

Run: `swift test --filter TypedRestPositioning`
Expected:
- `sixFourTypedRestsHitTheirStartBeats` — FAIL (today both rests centre to nearly the same X, so `xs[0] < xs[1]` may not hold cleanly).
- `measureRestStillCenters` — likely PASSES on the current code (because today everything `.whole` centres, including `.measure` after split). It will continue to pass after the fix.

The first failing test is the regression target; the second is a paired control that proves the fix doesn't regress measure-fill centring.

- [ ] **Step 3: Tighten the predicate in `LayoutEngine+Placement.swift`**

Open `Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift`. Find the rest-X branch (lines ~489–517 — search for "Whole-measure rest: ALWAYS centered horizontally"). Replace the comment block + `let isWholeRest = …` + the `if isWholeRest { … }` body, keeping the surrounding `restY` and leger-line code untouched.

Before:

```swift
                    // Whole-measure rest: ALWAYS centered horizontally
                    // in the measure body, even when other voices
                    // carry content — that's how MuseScore engraves
                    // it (`Rest::layout` falls into the
                    // `centerInMeasure` branch whenever the rest's
                    // duration spans the full measure, irrespective
                    // of voice multiplicity). The vertical offset
                    // assigned by `restVoiceOffset` keeps voice 2 /
                    // 3 / 4 rests off voice 1's melody line, so
                    // centering doesn't introduce any actual
                    // collision.
                    let isWholeRest = restBase == .whole
                    let restX: CGFloat
                    if isWholeRest {
                        // Centre the rest in the measure's chord
                        // area: midpoint of [contentStart,
                        // width − trailingPadding]. Must track
                        // `minimumMeasureWidth.rightPadding` and
                        // `chordSpacingTickToX.trailingGap` —
                        // otherwise the rest drifts off-centre
                        // whenever those constants are tuned.
                        let trailingPad = metrics.sp * 1
                        restX = (
                            headerSchedule.contentStartX
                                + width - trailingPad,
                        ) / 2
                    } else {
                        restX = timedX(atTick: tickCursor)
                    }
```

After:

```swift
                    // Centre only true measure-fill markers
                    // (`NoteDuration.measure`). Typed `.whole`
                    // rests carry an explicit duration and sit on
                    // their start beat — MuseScore's data model:
                    // a "centred" rest in any voice is authored as
                    // `<durationType>measure</…>`, not
                    // `<durationType>whole</…>`. With
                    // `NoteDuration.measure` present in the model,
                    // this distinction is honoured.
                    let isMeasureRest: Bool = {
                        if case .measure = r.duration { return true }
                        return false
                    }()
                    let restX: CGFloat
                    if isMeasureRest {
                        // Centre the rest in the measure's chord
                        // area: midpoint of [contentStart,
                        // width − trailingPadding]. Must track
                        // `minimumMeasureWidth.rightPadding` and
                        // `chordSpacingTickToX.trailingGap` —
                        // otherwise the rest drifts off-centre
                        // whenever those constants are tuned.
                        let trailingPad = metrics.sp * 1
                        restX = (
                            headerSchedule.contentStartX
                                + width - trailingPad,
                        ) / 2
                    } else {
                        restX = timedX(atTick: tickCursor)
                    }
```

- [ ] **Step 4: Run the regression test — expect it to pass now**

Run: `swift test --filter TypedRestPositioning/sixFourTypedRestsHitTheirStartBeats`
Expected: PASS — the typed `.whole` now sits at `timedX(atTick: 0)` and the `.half` at `timedX(atTick: 4 * 480)`, so `xs[0] < xs[1]`.

Run: `swift test --filter TypedRestPositioning/measureRestStillCenters`
Expected: PASS — `.measure` still routes through the centring branch.

- [ ] **Step 5: Migrate the `MultiStaffAlignmentTests` voice-1 fixture**

In `Tests/SheetMusicTests/MultiStaffAlignmentTests.swift`, change line 200:

Before:

```swift
                Voice(elements: [
                    .rest(duration: .whole),
                ]),
```

After:

```swift
                Voice(elements: [
                    // `.measure` (not `.whole`) is the
                    // MuseScore-canonical spelling for a
                    // measure-filling rest in voice 1 alongside
                    // voice 0's melody. With `NoteDuration.measure`
                    // present in the model, the layout engine
                    // centres only `.measure`; typed `.whole`
                    // rests sit on their start beat. This
                    // fixture's intent is the centring case, so
                    // it should use `.measure`.
                    .rest(duration: .measure),
                ]),
            ])
```

(The closing `])` already exists — only the inner `Voice(...)` body changes.)

- [ ] **Step 6: Run the full test suite**

Run: `swift test`
Expected: success — same pass count as before plus 2 new tests (1083/0/1 if the prior baseline was 1081/0/1).

Run: `swift test --filter MultiStaffAlignmentTests/multiVoiceWholeRestCentersInMeasure`
Expected: PASS — the migrated fixture preserves the original centring intent.

Run: `swiftlint --quiet Sources Tests`
Expected: no new warnings/errors in touched files. Pre-existing warnings in unrelated files are not Task 1's concern.

- [ ] **Step 7: Commit**

```bash
git add Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift \
        Tests/SheetMusicTests/MultiStaffAlignmentTests.swift \
        Tests/SheetMusicTests/TypedRestPositioningTests.swift
git commit -m "$(cat <<'EOF'
layout: position typed rests at start beat; centre only .measure

The layout engine previously centred every rest whose
DurationInterpretation.split(...) resolved to (.whole, 0) — that
included both NoteDuration.measure markers and typed .whole rests.
Now that .measure is a first-class case (prior plan), narrow the
centring branch to .measure alone. Typed .whole rests flow through
timedX(atTick: cursor) like every other duration, so a 6/4 bar
authored as `whole + half` renders the whole at beat 1 and the
half at beat 5 instead of stacking both at the bar centre.

Migrate MultiStaffAlignmentTests' voice-1 rest fixture from
.whole to .measure so its centring assertion holds against the
new rule (the test's intent — "a measure-filling rest in voice 1
centres" — is preserved by the spelling change).

Add TypedRestPositioningTests with two regression cases:
  - 6/4 [.whole, .half] — whole's X strictly less than half's.
  - 6/4 [.measure] — .measure still centres comfortably right of
    the header.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review Checklist (run before handing off)

**Spec coverage:**
- §"One-place change" → Task 1 step 3.
- §"`restY` — unchanged" → confirmed in step 3 (only the rest-X branch is touched).
- §"Leger-line predicate — unchanged" → confirmed.
- §"Tests / new" → Task 1 step 1 (`TypedRestPositioningTests`).
- §"Tests / migrate" → Task 1 step 5 (`MultiStaffAlignmentTests` voice-1 fixture).
- §"Tests / inventory" → addressed in File Structure section above (other `.rest(duration: .whole)` fixtures don't assert position; left as `.whole`).

**Placeholder scan:** No "TBD" / "implement later" / "add validation" / "similar to Task N" in steps. Each step shows the actual code or command.

**Type consistency:**
- `r.duration` is the `NoteDuration` on the empty-chord rest case — matches the surrounding switch's binding (`case let .chord(r) where r.notes.isEmpty:` per the file's existing structure).
- `restBase` is still bound from `DurationInterpretation.split(r.duration)` higher in the function and is still used for `restY` and the leger predicate — not removed.
- `headerSchedule.contentStartX` and `metrics.sp` are unchanged identifiers.
- `NoteDuration.measure` is the case added in the prior plan; available throughout `SheetMusicCore`.

**Risk re-check:**
- Test inventory (other `.whole` rest fixtures) was confirmed before writing the plan. None of them assert `.x` of the rest, so they will continue to pass even though the rest's X moves visually.
- `Sources/RenderPreviews/Samples.swift` will visually change but is not under test.
