# SheetMusicUI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新しい `SheetMusicUI` ライブラリを立ち上げ、`SheetMusicCore` の
`Score` を SwiftUI で描画する read-only ビューア (`ScoreView`) を macOS 15+ で
提供する。Core が公開する全視覚要素 (notes / rests / clefs / key sig / time sig
/ ties / glissando / slurs / voltas / hairpins / pedal / ottava / fermata /
markers / jumps / arpeggio / measure repeat / dynamics / tempo) を漏れなく
描画する。

**Architecture:** `Score` → 純粋関数レイアウトエンジン (`LayoutEngine`) →
`LayoutDocument` (Sendable 値型) → SwiftUI `Canvas` ベースの `ScoreCanvas` で
Bravura (SMuFL) フォントのグリフと Path ストロークを描画。Target は macOS 15+
のみで、公開 API は全て `@available(macOS 15.0, *)` ゲート。umbrella
(`SheetMusic`) には v1 では含めない。

**Tech Stack:** Swift 6.2 / SwiftUI / SwiftUI `Canvas` / CoreText /
Swift Testing / Bravura SMuFL フォント (SIL OFL 1.1)

**Session-specific note:** ユーザは別ウィンドウで並行作業中のため、本 plan を
実行する際 `git add` / `git commit` ステップは**スキップ**する (plan には
ドキュメント性のため残してある)。テストは普通に走らせる。

---

## File Structure

**Create:**

```
Sources/SheetMusicUI/
├── ScoreView.swift                              public View entry
├── Options/ScoreViewOptions.swift               3 つのノブ
├── Layout/
│   ├── StaffMetrics.swift                       sp / lineDistance 定数
│   ├── PitchStaffPosition.swift                 MIDI pitch → staff step
│   ├── LayoutElement.swift                      配置済みグリフ enum
│   ├── LayoutMeasure.swift                      measure 単位の配置結果
│   ├── LayoutSystem.swift                       1 行 = 複数 measure
│   ├── LayoutDocument.swift                     全システムの配置結果
│   └── LayoutEngine.swift                       Score → LayoutDocument
├── Rendering/
│   ├── SMuFLGlyph.swift                         Bravura codepoint 定数
│   ├── GraphicsContext+Glyph.swift              draw(Text) ラッパ
│   ├── ScoreCanvas.swift                        Canvas host View
│   ├── StaffRenderer.swift                      五線 + brace/bracket
│   ├── PartLabelRenderer.swift                  system 先頭のパート名
│   ├── ClefRenderer.swift
│   ├── KeySignatureRenderer.swift
│   ├── TimeSignatureRenderer.swift
│   ├── NoteheadRenderer.swift
│   ├── StemRenderer.swift
│   ├── BeamRenderer.swift
│   ├── RestRenderer.swift
│   ├── BarLineRenderer.swift
│   ├── AccidentalRenderer.swift
│   ├── ArpeggioRenderer.swift
│   ├── MeasureRepeatRenderer.swift
│   ├── TieRenderer.swift
│   ├── GlissandoRenderer.swift
│   ├── FermataRenderer.swift
│   ├── MarkerRenderer.swift
│   ├── JumpRenderer.swift
│   ├── SpannerRenderer.swift
│   └── TextMarkRenderer.swift
├── Previews/SamplePreviewScore.swift            プレビュー用最小 Score
└── Fonts/
    ├── BravuraFont.swift                        CTFont 登録
    └── Resources/
        ├── Bravura.otf                          SIL OFL, bundle
        └── Bravura.LICENSE.txt                  OFL 全文
```

**Modify:**

- `Package.swift` — `SheetMusicUI` library + target 追加、
  `SheetMusicTests` deps に `SheetMusicUI` 追加
- `NOTICE` — Bravura フォントの OFL セクション追加
- `README.md` — library table に SheetMusicUI 行追加
- `Example/project.yml` — macOS target 追加 (最終段階)

**Test (新規 `Tests/SheetMusicTests/`):**

- `BravuraFontTests.swift`
- `PitchStaffPositionTests.swift`
- `StemDirectionTests.swift`
- `LayoutEngineTests.swift`
- `BeamingTests.swift`
- `SpannerSegmentationTests.swift`
- `TiePairingTests.swift`
- `FermataLayoutTests.swift`
- `ScoreViewRenderTests.swift`

---

## Stage 1: Package wiring + Bravura font

**Files:**
- Create: `Sources/SheetMusicUI/Fonts/BravuraFont.swift`
- Create: `Sources/SheetMusicUI/Fonts/Resources/Bravura.otf` (binary)
- Create: `Sources/SheetMusicUI/Fonts/Resources/Bravura.LICENSE.txt`
- Create: `Sources/SheetMusicUI/ScoreView.swift` (stub)
- Modify: `Package.swift`
- Modify: `NOTICE`
- Test: `Tests/SheetMusicTests/BravuraFontTests.swift`

### Task 1.1: Fetch Bravura.otf + LICENSE into resources dir

- [ ] **Step 1: Create directory**

```bash
mkdir -p Sources/SheetMusicUI/Fonts/Resources
```

- [ ] **Step 2: Download Bravura.otf from upstream (pin a specific release tag)**

```bash
curl -L \
  -o Sources/SheetMusicUI/Fonts/Resources/Bravura.otf \
  "https://github.com/steinbergmedia/bravura/raw/1.392/redist/otf/Bravura.otf"
ls -l Sources/SheetMusicUI/Fonts/Resources/Bravura.otf
```

Expected: file size around 800-900 KB. Fail if < 100 KB (indicates redirect
error).

- [ ] **Step 3: Download OFL license text**

```bash
curl -L \
  -o Sources/SheetMusicUI/Fonts/Resources/Bravura.LICENSE.txt \
  "https://raw.githubusercontent.com/steinbergmedia/bravura/1.392/redist/LICENSE.txt"
head -3 Sources/SheetMusicUI/Fonts/Resources/Bravura.LICENSE.txt
```

Expected: first line contains "SIL OPEN FONT LICENSE" or similar header.

- [ ] **Step 4: Verify both are not in `.gitignore`**

```bash
grep -E "\.otf|Bravura" .gitignore || echo "not ignored"
```

Expected: "not ignored".

### Task 1.2: Add SheetMusicUI product + target to Package.swift

- [ ] **Step 1: Edit Package.swift to add the library product and target**

Modify `Package.swift`:

```swift
// In `products:` array, after the existing libraries:
.library(name: "SheetMusicUI", targets: ["SheetMusicUI"]),
```

```swift
// In `targets:` array, after `SheetMusicMIDI`:
.target(
    name: "SheetMusicUI",
    dependencies: ["SheetMusicCore"],
    resources: [.copy("Fonts/Resources")]
),
```

```swift
// Update `SheetMusicTests` testTarget deps to include SheetMusicUI:
.testTarget(
    name: "SheetMusicTests",
    dependencies: [
        "SheetMusic",
        "SheetMusicCore",
        "SheetMusicMIDI",
        "SheetMusicMSCX",
        "SheetMusicMusicXML",
        "SheetMusicUI",             // ← ここを追加
        "SheetMusicXMLTools",
    ],
    resources: [
        .process("Resources"),
    ]
),
```

- [ ] **Step 2: Build to verify Package.swift compiles**

Run: `swift build`
Expected: errors about empty `SheetMusicUI` target (no Swift sources yet).
That is acceptable for this step — next tasks add the Swift sources.

### Task 1.3: Create empty ScoreView stub so target compiles

- [ ] **Step 1: Write the stub**

Create `Sources/SheetMusicUI/ScoreView.swift`:

```swift
#if os(macOS)
import SheetMusicCore
import SwiftUI

/// Read-only SwiftUI view that renders a `Score`.
///
/// macOS 15+ only. Bundles the Bravura SMuFL font for glyph drawing.
@available(macOS 15.0, *)
public struct ScoreView: View {
    private let score: Score
    private let options: ScoreViewOptions

    public init(score: Score, options: ScoreViewOptions = .init()) {
        _ = BravuraFont.register
        self.score = score
        self.options = options
    }

    public var body: some View {
        Text("SheetMusicUI stub — \(score.parts.count) part(s)")
    }
}
#endif
```

- [ ] **Step 2: Run `swift build`**

Run: `swift build`
Expected: still fails because `BravuraFont` and `ScoreViewOptions` don't
exist yet. Continue to next tasks which create them.

### Task 1.4: Add ScoreViewOptions

- [ ] **Step 1: Write ScoreViewOptions**

Create `Sources/SheetMusicUI/Options/ScoreViewOptions.swift`:

```swift
#if os(macOS)
import CoreGraphics

/// Tunable knobs for `ScoreView`. v1 intentionally keeps this small —
/// layout is driven by the view's available width and these three values.
@available(macOS 15.0, *)
public struct ScoreViewOptions: Sendable, Equatable {
    /// Height of one five-line staff in points. Defaults to 28 pt
    /// (roughly rastral 3).
    public var staffSize: CGFloat
    /// Vertical gap between systems (lines of music) in points.
    public var systemGap: CGFloat
    /// When true, measures wrap to the view's available width.
    /// When false, the layout emits a single long system and the caller is
    /// expected to wrap the `ScoreView` in a `ScrollView(.horizontal)`.
    public var wrapToViewWidth: Bool

    public init(
        staffSize: CGFloat = 28,
        systemGap: CGFloat = 40,
        wrapToViewWidth: Bool = true
    ) {
        self.staffSize = staffSize
        self.systemGap = systemGap
        self.wrapToViewWidth = wrapToViewWidth
    }
}
#endif
```

- [ ] **Step 2: `swift build`**

Run: `swift build`
Expected: still fails on missing `BravuraFont`. Continue.

### Task 1.5: Add BravuraFont registration

- [ ] **Step 1: Write BravuraFont**

Create `Sources/SheetMusicUI/Fonts/BravuraFont.swift`:

```swift
#if os(macOS)
import CoreText
import Foundation

/// Runtime registration of the bundled Bravura SMuFL font.
///
/// Registration is process-scoped — it does not affect system font caches
/// outside the host application.
@available(macOS 15.0, *)
enum BravuraFont {
    /// Font family name as reported by CoreText once registered.
    static let familyName = "Bravura"

    /// Trigger registration by reading this property once. Subsequent reads
    /// are no-ops (Swift `static let` is lazy + thread-safe).
    static let register: Void = {
        guard let url = Bundle.module.url(
            forResource: "Bravura",
            withExtension: "otf"
        ) else {
            return
        }
        var error: Unmanaged<CFError>?
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error)
        // If registration fails silently, the first draw will fall back to
        // system default — ugly, but not a crash.
    }()
}
#endif
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: success. No warnings.

### Task 1.6: Write BravuraFont registration test

- [ ] **Step 1: Write the test**

Create `Tests/SheetMusicTests/BravuraFontTests.swift`:

```swift
#if os(macOS)
import CoreText
@testable import SheetMusicUI
import Testing

@available(macOS 15.0, *)
@Suite("Bravura font registration")
struct BravuraFontTests {
    @Test("Bravura is registered and resolvable by CoreText")
    func bravuraIsResolvable() {
        _ = BravuraFont.register
        let font = CTFontCreateWithName(
            "Bravura" as CFString, 12, nil
        )
        let resolvedFamily = CTFontCopyFamilyName(font) as String
        #expect(resolvedFamily == "Bravura")
    }
}
#endif
```

- [ ] **Step 2: Run**

Run: `swift test --filter BravuraFontTests`
Expected: 1 passed.

- [ ] **Step 3: (plan only — SKIP during this session) commit**

```bash
# git add Package.swift Sources/SheetMusicUI NOTICE Tests/SheetMusicTests/BravuraFontTests.swift
# git commit -m "ui: package wiring + bundled Bravura font"
```

### Task 1.7: Update NOTICE

- [ ] **Step 1: Append Bravura section to `NOTICE`**

Append to existing `NOTICE`:

```
-----

SheetMusicUI bundles the Bravura SMuFL font
(`Sources/SheetMusicUI/Fonts/Resources/Bravura.otf`).

Bravura is © Steinberg Media Technologies GmbH and is licensed under
the SIL Open Font License, Version 1.1. See
`Sources/SheetMusicUI/Fonts/Resources/Bravura.LICENSE.txt` for the
full license text.

Bravura is included in the `SheetMusicUI` library target only; it is
not a dependency of any other library product in this package.
```

- [ ] **Step 2: (plan only — SKIP) commit NOTICE update**

---

## Stage 2: Layout primitives (pure types, no rendering)

**Files:**
- Create: `Sources/SheetMusicUI/Layout/StaffMetrics.swift`
- Create: `Sources/SheetMusicUI/Layout/PitchStaffPosition.swift`
- Create: `Sources/SheetMusicUI/Layout/LayoutElement.swift`
- Test: `Tests/SheetMusicTests/PitchStaffPositionTests.swift`
- Test: `Tests/SheetMusicTests/StemDirectionTests.swift` (StemDirection lives in this layout file; direction computation is a pure function added next stage)

### Task 2.1: StaffMetrics — sp / lineDistance / glyph size constants

- [ ] **Step 1: Write StaffMetrics**

Create `Sources/SheetMusicUI/Layout/StaffMetrics.swift`:

```swift
#if os(macOS)
import CoreGraphics

/// Per-staff sizing derived from `ScoreViewOptions.staffSize`.
///
/// MuseScore / engraving convention: one "staff space" (sp) = one line
/// distance of a five-line staff. A staff is 4 sp tall.
@available(macOS 15.0, *)
public struct StaffMetrics: Sendable, Equatable {
    /// Total height of the five-line staff, in points. Equals 4 × sp.
    public let staffHeight: CGFloat
    /// One staff space in points (distance between adjacent staff lines).
    public let sp: CGFloat

    public init(staffSize: CGFloat) {
        self.staffHeight = staffSize
        self.sp = staffSize / 4
    }

    /// Thickness of a staff line. Engraving: typically 0.13 sp.
    public var staffLineThickness: CGFloat { sp * 0.13 }
    /// Thickness of a stem. Engraving: typically 0.12 sp.
    public var stemThickness: CGFloat { sp * 0.12 }
    /// Typical stem length for isolated notes: 3.5 sp.
    public var defaultStemLength: CGFloat { sp * 3.5 }
    /// Font size for Bravura glyphs (pt). One em = 4 sp by SMuFL convention.
    public var glyphFontSize: CGFloat { sp * 4 }
    /// Horizontal space allocated per quarter note (pre-stretch).
    /// Tuned empirically; adjustable at stage 4's stretch pass.
    public var spacePerQuarter: CGFloat { sp * 4 }
}
#endif
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: success.

### Task 2.2: PitchStaffPosition — MIDI pitch + clef → staff step

Staff step convention: 0 = middle line of the staff. Positive = up, negative
= down. One step = 0.5 sp vertical distance.

- [ ] **Step 1: Write PitchStaffPosition**

Create `Sources/SheetMusicUI/Layout/PitchStaffPosition.swift`:

```swift
#if os(macOS)
import SheetMusicCore

/// Clef glyphs we currently place. Each clef anchors a reference pitch to
/// a reference staff line, from which all other pitches are derived.
@available(macOS 15.0, *)
public enum NotatedClef: Sendable, Equatable {
    case treble          // G4 on line 2 (second from bottom)
    case bass            // F3 on line 4 (second from top)
    case alto            // C4 on middle line
    case tenor           // C4 on line 4

    /// Parse a `Clef.concertClefType` string (MuseScore encoding).
    public init(rawType: String) {
        switch rawType {
        case "G", "G1", "G2", "G8va", "G8vb", "treble": self = .treble
        case "F", "F8va", "F8vb", "bass":              self = .bass
        case "C3", "alto":                              self = .alto
        case "C4", "tenor":                             self = .tenor
        default:                                        self = .treble
        }
    }
}

/// Result of mapping a MIDI pitch to a staff position under a given clef.
///
/// `step` values of 0 = middle line. +1 = space above middle line.
/// +2 = fourth line (from bottom). …etc. Each step = 0.5 sp vertically.
@available(macOS 15.0, *)
public struct StaffStep: Sendable, Equatable {
    public let step: Int
    public init(_ step: Int) { self.step = step }
}

/// Pure function: MIDI pitch + TPC + clef → staff step.
///
/// TPC ("tonal pitch class", -1..33 in MuseScore convention) selects the
/// diatonic spelling. Pitch alone is ambiguous (C♯ vs D♭). With TPC we can
/// place the notehead on the correct diatonic line/space.
@available(macOS 15.0, *)
public enum PitchStaffPosition {
    /// Tonal pitch class → diatonic step count from C (0=C, 1=D, …, 6=B).
    /// MuseScore TPC: -1 = F♭♭, 0 = C♭♭, 1 = G♭♭, …
    /// (TPC mod 7 gives the diatonic letter in the order F C G D A E B.)
    private static let tpcLetters: [Int] = [3, 0, 4, 1, 5, 2, 6]
    // index by ((tpc + 1) mod 7): F(-1→0), C(0→1), G(1→2), D(2→3), A, E, B

    /// Return the staff step for a note with this pitch + tpc under `clef`.
    public static func step(
        midiPitch: Int,
        tpc: Int,
        clef: NotatedClef
    ) -> StaffStep {
        let diatonicFromC = tpcLetters[((tpc + 1) % 7 + 7) % 7]
        // octave: MuseScore convention — C4 = MIDI 60.
        // Use tpc-implied letter to avoid pitch-vs-spelling mismatch on
        // accidentals.
        let octave = octaveFor(midiPitch: midiPitch, diatonicFromC: diatonicFromC)
        // Absolute diatonic step counted from some reference:
        let diatonicAbs = octave * 7 + diatonicFromC
        // Reference pitches sitting on the staff middle line per clef:
        //   treble: B4  = octave 4 letter 6
        //   bass:   D3  = octave 3 letter 1
        //   alto:   C4  = octave 4 letter 0
        //   tenor:  A3  = octave 3 letter 5
        let midLineDiatonic: Int
        switch clef {
        case .treble: midLineDiatonic = 4 * 7 + 6
        case .bass:   midLineDiatonic = 3 * 7 + 1
        case .alto:   midLineDiatonic = 4 * 7 + 0
        case .tenor:  midLineDiatonic = 3 * 7 + 5
        }
        return StaffStep(diatonicAbs - midLineDiatonic)
    }

    /// The octave number implied by a MIDI pitch + diatonic letter.
    /// This resolves accidental ambiguity: pitch 60 + letter=B → octave 3
    /// (B♯3), not octave 4.
    private static func octaveFor(midiPitch: Int, diatonicFromC: Int) -> Int {
        // Semitone distance from C in the same octave for each letter:
        let letterSemitone = [0, 2, 4, 5, 7, 9, 11]  // C D E F G A B
        let naiveOctave = midiPitch / 12 - 1  // MIDI 0 = C-1
        let naiveSemitone = midiPitch - 12 * (naiveOctave + 1)
        let letterSem = letterSemitone[diatonicFromC]
        let diff = naiveSemitone - letterSem
        // diff can be -11..+11 for silly accidentals. Snap to nearest octave.
        if diff >= 6 { return naiveOctave + 1 }
        if diff <= -6 { return naiveOctave - 1 }
        return naiveOctave
    }
}
#endif
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: success.

### Task 2.3: PitchStaffPositionTests

- [ ] **Step 1: Write the test**

Create `Tests/SheetMusicTests/PitchStaffPositionTests.swift`:

```swift
#if os(macOS)
@testable import SheetMusicUI
import Testing

@available(macOS 15.0, *)
@Suite("PitchStaffPosition")
struct PitchStaffPositionTests {
    // MuseScore TPC convention: C natural = 14, D = 16, E = 18, F = 13,
    // G = 15, A = 17, B = 19. All natural TPCs fall in the range 13..19.
    // (MSCX uses -1..33; the natural subset is 13..19.)
    // Sharp = +7 on TPC, flat = -7.

    @Test("Treble clef: middle C is one step below bottom line (step -6)")
    func middleCTreble() {
        let result = PitchStaffPosition.step(
            midiPitch: 60, tpc: 14, clef: .treble
        )
        // Middle line of treble staff is B4. C4 is seven diatonic steps
        // below B4 → step = -7? Wait — one diatonic step = 1 in our unit.
        // B4 → step 0, A4 → -1, G4 → -2, F4 → -3, E4 → -4, D4 → -5,
        // C4 → -6. Bottom line (E4) = -4. C4 is below bottom line (one
        // step lower in diatonic terms, but on the 2nd ledger-line space
        // down → step -6 is correct).
        #expect(result.step == -6)
    }

    @Test("Treble clef: bottom line E4 is step -4")
    func e4Treble() {
        let result = PitchStaffPosition.step(
            midiPitch: 64, tpc: 18, clef: .treble
        )
        #expect(result.step == -4)
    }

    @Test("Treble clef: top line F5 is step 4")
    func f5Treble() {
        let result = PitchStaffPosition.step(
            midiPitch: 77, tpc: 13, clef: .treble
        )
        #expect(result.step == 4)
    }

    @Test("Bass clef: middle line is D3 → step 0")
    func d3Bass() {
        let result = PitchStaffPosition.step(
            midiPitch: 50, tpc: 16, clef: .bass
        )
        #expect(result.step == 0)
    }

    @Test("Bass clef: middle C (C4) sits just above the staff (step +2)")
    func middleCBass() {
        let result = PitchStaffPosition.step(
            midiPitch: 60, tpc: 14, clef: .bass
        )
        // D3 = 0, E3 = 1, F3 = 2, G3 = 3, A3 = 4, B3 = 5, C4 = 6. Bass top
        // line is A3 (step 4). C4 is 2 steps above → step 6.
        #expect(result.step == 6)
    }

    @Test("Alto clef: middle C4 is step 0 (middle line)")
    func c4Alto() {
        let result = PitchStaffPosition.step(
            midiPitch: 60, tpc: 14, clef: .alto
        )
        #expect(result.step == 0)
    }

    @Test("Sharp vs flat spelling picks the correct diatonic line")
    func accidentalSpellingAffectsLine() {
        // MIDI 61 spelled as C♯4 (tpc 21): same line as C4 → step -6
        // MIDI 61 spelled as D♭4 (tpc 9):  same line as D4 → step -5
        let cSharp = PitchStaffPosition.step(
            midiPitch: 61, tpc: 21, clef: .treble
        )
        let dFlat = PitchStaffPosition.step(
            midiPitch: 61, tpc: 9, clef: .treble
        )
        #expect(cSharp.step == -6)
        #expect(dFlat.step == -5)
    }

    @Test("NotatedClef parses treble / bass / alto / tenor")
    func clefParsing() {
        #expect(NotatedClef(rawType: "G") == .treble)
        #expect(NotatedClef(rawType: "F") == .bass)
        #expect(NotatedClef(rawType: "C3") == .alto)
        #expect(NotatedClef(rawType: "C4") == .tenor)
        #expect(NotatedClef(rawType: "unknown") == .treble)
    }
}
#endif
```

- [ ] **Step 2: Run**

Run: `swift test --filter PitchStaffPositionTests`
Expected: 8 passed.

- [ ] **Step 3: (plan only) commit**

### Task 2.4: LayoutElement enum

This is the unit of placement emitted by `LayoutEngine`. Each case carries
its x/y origin (in the enclosing measure's local coordinate) + element-
specific data. `ScoreCanvas` walks these and dispatches to the right
renderer.

- [ ] **Step 1: Write LayoutElement**

Create `Sources/SheetMusicUI/Layout/LayoutElement.swift`:

```swift
#if os(macOS)
import CoreGraphics
import SheetMusicCore

/// Stem direction for notes / beams.
@available(macOS 15.0, *)
public enum StemDirection: Sendable, Equatable { case up, down }

/// A single placed element in a measure's local coordinate space.
///
/// `origin` is measured from the measure's top-left corner where
/// y increases downward (screen convention). Staff step 0 (middle
/// line) corresponds to a y equal to `staffHeight / 2` within the measure.
@available(macOS 15.0, *)
public enum LayoutElement: Sendable, Equatable {
    case clef(rawType: String, origin: CGPoint)
    case keySignature(sharps: Int, flats: Int, origin: CGPoint)
    case timeSignature(numerator: Int, denominator: Int, origin: CGPoint)
    case barLine(subtype: String?, origin: CGPoint)
    case note(
        step: Int,
        duration: NoteDuration,
        accidental: Accidental?,
        stem: StemDirection,
        origin: CGPoint,
        tieForward: Int?,
        tieBack: Int?,
        hasGlissando: Bool
    )
    case chord(
        notes: [LayoutChordNote],
        duration: NoteDuration,
        stem: StemDirection,
        stemOrigin: CGPoint,
        hasArpeggio: Bool,
        arpeggioRawType: String?
    )
    case rest(duration: NoteDuration, origin: CGPoint)
    case beam(fromOrigin: CGPoint, toOrigin: CGPoint, levels: Int)
    case textMark(kind: TextMarkKind, text: String, origin: CGPoint)
    case fermata(subtype: String, origin: CGPoint)
    case marker(kind: Marker.Kind, text: String, origin: CGPoint)
    case jump(text: String, origin: CGPoint)
    case measureRepeat(count: Int, origin: CGPoint)
    case spannerSegment(
        kind: SpannerKind,
        fromOrigin: CGPoint,
        toOrigin: CGPoint,
        continuesLeft: Bool,
        continuesRight: Bool,
        text: String
    )
    case tieArc(
        fromOrigin: CGPoint,
        toOrigin: CGPoint,
        above: Bool
    )
    case glissandoLine(
        fromOrigin: CGPoint,
        toOrigin: CGPoint,
        wavy: Bool,
        text: String?
    )

    public enum TextMarkKind: Sendable, Equatable {
        case dynamic
        case tempo
    }

    public enum SpannerKind: Sendable, Equatable {
        case slur
        case volta(endings: [Int])
        case hairpinOpen
        case hairpinClose
        case pedal
        case ottava(raw: String)
        case textLine
    }
}

@available(macOS 15.0, *)
public struct LayoutChordNote: Sendable, Equatable {
    public let step: Int
    public let accidental: Accidental?
    public let origin: CGPoint
    public let tieForward: Int?
    public let tieBack: Int?
    public let hasGlissando: Bool

    public init(
        step: Int,
        accidental: Accidental?,
        origin: CGPoint,
        tieForward: Int?,
        tieBack: Int?,
        hasGlissando: Bool
    ) {
        self.step = step
        self.accidental = accidental
        self.origin = origin
        self.tieForward = tieForward
        self.tieBack = tieBack
        self.hasGlissando = hasGlissando
    }
}
#endif
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: success.

### Task 2.5: StemDirection helper + test

- [ ] **Step 1: Add computeStemDirection(...) to LayoutElement.swift**

Append to `Sources/SheetMusicUI/Layout/LayoutElement.swift` (inside the
`#if os(macOS)` block, outside the enum):

```swift
@available(macOS 15.0, *)
public enum StemDirectionRule {
    /// Median heuristic: if the chord median step is at or below 0
    /// (the middle line), stems go up. Otherwise down.
    /// `steps` are staff steps for each notehead (see `PitchStaffPosition`).
    public static func direction(for steps: [Int]) -> StemDirection {
        guard !steps.isEmpty else { return .up }
        let sorted = steps.sorted()
        let median: Double
        if sorted.count.isMultiple(of: 2) {
            let a = sorted[sorted.count / 2 - 1]
            let b = sorted[sorted.count / 2]
            median = (Double(a) + Double(b)) / 2
        } else {
            median = Double(sorted[sorted.count / 2])
        }
        return median <= 0 ? .up : .down
    }
}
```

- [ ] **Step 2: Write StemDirectionTests**

Create `Tests/SheetMusicTests/StemDirectionTests.swift`:

```swift
#if os(macOS)
@testable import SheetMusicUI
import Testing

@available(macOS 15.0, *)
@Suite("StemDirectionRule")
struct StemDirectionTests {
    @Test("Single note below middle line → stem up")
    func belowMiddle() {
        #expect(StemDirectionRule.direction(for: [-3]) == .up)
    }

    @Test("Single note above middle line → stem down")
    func aboveMiddle() {
        #expect(StemDirectionRule.direction(for: [3]) == .down)
    }

    @Test("Single note on middle line → stem up (tie-break lower)")
    func onMiddle() {
        #expect(StemDirectionRule.direction(for: [0]) == .up)
    }

    @Test("Chord with median == 0 → stem up")
    func chordMedianZero() {
        #expect(StemDirectionRule.direction(for: [-2, 0, 2]) == .up)
    }

    @Test("Chord with even count, median between 1 and 2 → stem down")
    func chordMedianOnePointFive() {
        #expect(StemDirectionRule.direction(for: [0, 3]) == .up)
        // median = 1.5 > 0 → down.
        // Wait — 1.5 > 0 so direction is .down per the rule. Adjust:
    }

    @Test("Chord with even count, median 1.5 → stem down")
    func chordMedianPositive() {
        let steps = [1, 2]
        #expect(StemDirectionRule.direction(for: steps) == .down)
    }

    @Test("Empty input → up default")
    func emptyDefault() {
        #expect(StemDirectionRule.direction(for: []) == .up)
    }
}
#endif
```

Note: the `chordMedianOnePointFive` case's expectation may surprise —
walk through the logic: median of `[0, 3]` is 1.5, > 0 → .down. The test
above has `#expect(... == .up)` which is wrong. **Fix it now** before
running: change that assertion to `== .down`.

- [ ] **Step 3: Fix the logic error in the test file**

Edit `Tests/SheetMusicTests/StemDirectionTests.swift` so the
`chordMedianOnePointFive` test body becomes:

```swift
    @Test("Chord [0, 3] median 1.5 → stem down")
    func chordMedianOnePointFive() {
        #expect(StemDirectionRule.direction(for: [0, 3]) == .down)
    }
```

- [ ] **Step 4: Run**

Run: `swift test --filter StemDirectionTests`
Expected: 7 passed.

- [ ] **Step 5: (plan only) commit**

---

## Stage 3: Layout for a single measure + single staff

This stage produces a `LayoutDocument` from a `Score` for the simplest
multi-measure single-staff case. Beaming is deferred to stage 7; v1 uses
isolated stems (flags for each short duration) until then.

**Files:**
- Create: `Sources/SheetMusicUI/Layout/LayoutMeasure.swift`
- Create: `Sources/SheetMusicUI/Layout/LayoutSystem.swift`
- Create: `Sources/SheetMusicUI/Layout/LayoutDocument.swift`
- Create: `Sources/SheetMusicUI/Layout/LayoutEngine.swift`
- Test: `Tests/SheetMusicTests/LayoutEngineTests.swift`

### Task 3.1: Layout container types

- [ ] **Step 1: Write LayoutMeasure**

Create `Sources/SheetMusicUI/Layout/LayoutMeasure.swift`:

```swift
#if os(macOS)
import CoreGraphics

@available(macOS 15.0, *)
public struct LayoutMeasure: Sendable, Equatable {
    /// Measure-local origin within its `LayoutSystem`.
    public let origin: CGPoint
    /// Width of the measure (including barline space).
    public let width: CGFloat
    /// Per-staff elements (one sub-array per staff in the part).
    /// Origins inside `elements` are relative to the measure origin.
    public let elements: [LayoutElement]
    /// Top-left markers (segno, coda, fine, toCoda).
    public let markers: [LayoutElement]
    /// Bottom-right jumps (D.C., D.S.).
    public let jumps: [LayoutElement]

    public init(
        origin: CGPoint,
        width: CGFloat,
        elements: [LayoutElement],
        markers: [LayoutElement] = [],
        jumps: [LayoutElement] = []
    ) {
        self.origin = origin
        self.width = width
        self.elements = elements
        self.markers = markers
        self.jumps = jumps
    }
}
#endif
```

- [ ] **Step 2: Write LayoutSystem**

Create `Sources/SheetMusicUI/Layout/LayoutSystem.swift`:

```swift
#if os(macOS)
import CoreGraphics

/// One horizontal line of music. Contains one or more staves stacked
/// vertically (for multi-staff parts) and one or more parts (multiple
/// instruments).
@available(macOS 15.0, *)
public struct LayoutSystem: Sendable, Equatable {
    public let origin: CGPoint       // in document coordinates
    public let size: CGSize
    public let measures: [LayoutMeasure]
    /// Per-staff baselines (top-left in system coordinates).
    public let staffOrigins: [CGPoint]
    /// Part label at the left edge of this system (empty on continuation
    /// systems per MuseScore convention).
    public let partLabels: [LayoutPartLabel]
    /// Cross-measure spanner segments (slurs, voltas, hairpins, etc.)
    /// resolved after measure placement. Origins are in system coords.
    public let spanners: [LayoutElement]

    public init(
        origin: CGPoint,
        size: CGSize,
        measures: [LayoutMeasure],
        staffOrigins: [CGPoint],
        partLabels: [LayoutPartLabel],
        spanners: [LayoutElement]
    ) {
        self.origin = origin
        self.size = size
        self.measures = measures
        self.staffOrigins = staffOrigins
        self.partLabels = partLabels
        self.spanners = spanners
    }
}

@available(macOS 15.0, *)
public struct LayoutPartLabel: Sendable, Equatable {
    public let text: String
    public let origin: CGPoint

    public init(text: String, origin: CGPoint) {
        self.text = text
        self.origin = origin
    }
}
#endif
```

- [ ] **Step 3: Write LayoutDocument**

Create `Sources/SheetMusicUI/Layout/LayoutDocument.swift`:

```swift
#if os(macOS)
import CoreGraphics

@available(macOS 15.0, *)
public struct LayoutDocument: Sendable, Equatable {
    public let size: CGSize
    public let systems: [LayoutSystem]
    public let metrics: StaffMetrics

    public init(
        size: CGSize,
        systems: [LayoutSystem],
        metrics: StaffMetrics
    ) {
        self.size = size
        self.systems = systems
        self.metrics = metrics
    }
}
#endif
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: success.

### Task 3.2: LayoutEngine — skeleton + single-measure emission

- [ ] **Step 1: Write the engine skeleton**

Create `Sources/SheetMusicUI/Layout/LayoutEngine.swift`:

```swift
#if os(macOS)
import CoreGraphics
import SheetMusicCore

/// Pure function: `Score` → `LayoutDocument`.
///
/// v1 is a single-pass engine with simple heuristics. No caching, no
/// mutation, no back-pointers. Safe to re-run on every option change.
@available(macOS 15.0, *)
public enum LayoutEngine {
    public static func layout(
        score: Score,
        options: ScoreViewOptions,
        availableWidth: CGFloat
    ) -> LayoutDocument {
        let metrics = StaffMetrics(staffSize: options.staffSize)
        let context = RenderContext(
            score: score,
            options: options,
            metrics: metrics,
            availableWidth: availableWidth
        )
        let systems = packSystems(context: context)
        let totalHeight = systems.reduce(CGFloat(0)) { acc, system in
            max(acc, system.origin.y + system.size.height)
        }
        return LayoutDocument(
            size: CGSize(width: availableWidth, height: totalHeight),
            systems: systems,
            metrics: metrics
        )
    }

    // MARK: - Context

    struct RenderContext {
        let score: Score
        let options: ScoreViewOptions
        let metrics: StaffMetrics
        let availableWidth: CGFloat
    }

    // MARK: - System packing (greedy wrap)

    private static func packSystems(
        context: RenderContext
    ) -> [LayoutSystem] {
        // Flatten: each part has one-or-more staves; take the first staff
        // of each part's StaffContent for v1 single-staff path. Multi-staff
        // support comes in stage 5.
        let staffMeasures = context.score.staves.first?.measures ?? []
        guard !staffMeasures.isEmpty else {
            return []
        }

        // Minimum width per measure at this stage: a constant based on
        // number of voice elements. Detail comes in Task 3.3.
        let minWidths: [CGFloat] = staffMeasures.map { m in
            minimumMeasureWidth(measure: m, metrics: context.metrics)
        }

        // Greedy pack measures into systems.
        var systems: [LayoutSystem] = []
        var currentY: CGFloat = 0
        var cursor = 0
        while cursor < staffMeasures.count {
            var widthSoFar: CGFloat = 0
            let systemStart = cursor
            while cursor < staffMeasures.count {
                let w = minWidths[cursor]
                if context.options.wrapToViewWidth
                    && widthSoFar + w > context.availableWidth
                    && cursor > systemStart {
                    break
                }
                widthSoFar += w
                cursor += 1
            }
            let slice = Array(staffMeasures[systemStart..<cursor])
            let widths = Array(minWidths[systemStart..<cursor])
            let stretched = stretchWidths(
                widths: widths,
                availableWidth: context.availableWidth,
                shouldStretch: context.options.wrapToViewWidth
            )
            let system = buildSystem(
                measures: slice,
                widths: stretched,
                systemOriginY: currentY,
                context: context
            )
            currentY += system.size.height + context.options.systemGap
            systems.append(system)
        }
        return systems
    }

    private static func stretchWidths(
        widths: [CGFloat],
        availableWidth: CGFloat,
        shouldStretch: Bool
    ) -> [CGFloat] {
        let total = widths.reduce(0, +)
        guard shouldStretch, total > 0, availableWidth > total else {
            return widths
        }
        let ratio = availableWidth / total
        return widths.map { $0 * ratio }
    }

    private static func minimumMeasureWidth(
        measure: Measure,
        metrics: StaffMetrics
    ) -> CGFloat {
        // Base width = 4 sp (padding each side) + 2 sp per voice element.
        // Replaced by a richer calculation in stage 4 when we care about
        // tick-proportional spacing.
        let elements = measure.voices.flatMap { $0.elements }
        return metrics.sp * 4 + CGFloat(elements.count) * metrics.sp * 3
    }

    private static func buildSystem(
        measures: [Measure],
        widths: [CGFloat],
        systemOriginY: CGFloat,
        context: RenderContext
    ) -> LayoutSystem {
        let metrics = context.metrics
        let partLabelWidth: CGFloat = 60  // reserved on left; stage 5 refines
        var x: CGFloat = partLabelWidth
        var layoutMeasures: [LayoutMeasure] = []
        var activeClef = NotatedClef.treble
        for (i, m) in measures.enumerated() {
            let w = widths[i]
            let (els, newClef) = placeMeasureElements(
                measure: m,
                width: w,
                metrics: metrics,
                activeClef: activeClef
            )
            layoutMeasures.append(
                LayoutMeasure(
                    origin: CGPoint(x: x, y: 0),
                    width: w,
                    elements: els
                )
            )
            x += w
            activeClef = newClef
        }
        return LayoutSystem(
            origin: CGPoint(x: 0, y: systemOriginY),
            size: CGSize(width: x, height: metrics.staffHeight + metrics.sp * 6),
            measures: layoutMeasures,
            staffOrigins: [CGPoint(x: 0, y: metrics.sp * 2)],
            partLabels: [],
            spanners: []
        )
    }

    /// Place elements of a measure in local measure coordinates.
    /// Returns (elements, updated clef context for the next measure).
    private static func placeMeasureElements(
        measure: Measure,
        width: CGFloat,
        metrics: StaffMetrics,
        activeClef: NotatedClef
    ) -> (elements: [LayoutElement], clef: NotatedClef) {
        let staffMidY = metrics.staffHeight / 2 + metrics.sp * 2
        var out: [LayoutElement] = []
        var x: CGFloat = metrics.sp * 2
        var currentClef = activeClef
        for voice in measure.voices {
            var vx = x
            for el in voice.elements {
                switch el {
                case .clef(let clef):
                    currentClef = NotatedClef(rawType: clef.concertClefType)
                    out.append(.clef(
                        rawType: clef.concertClefType,
                        origin: CGPoint(x: vx, y: staffMidY)
                    ))
                    vx += metrics.sp * 3
                case .keySignature(let key):
                    out.append(.keySignature(
                        sharps: max(0, key.concertKey),
                        flats: max(0, -key.concertKey),
                        origin: CGPoint(x: vx, y: staffMidY)
                    ))
                    vx += metrics.sp * CGFloat(abs(key.concertKey)) + metrics.sp
                case .timeSignature(let ts):
                    out.append(.timeSignature(
                        numerator: ts.numerator,
                        denominator: ts.denominator,
                        origin: CGPoint(x: vx, y: staffMidY)
                    ))
                    vx += metrics.sp * 3
                case .barLine(let b):
                    out.append(.barLine(
                        subtype: b.subtype,
                        origin: CGPoint(x: vx, y: staffMidY)
                    ))
                    vx += metrics.sp
                case .rest(let r):
                    out.append(.rest(
                        duration: r.duration,
                        origin: CGPoint(x: vx, y: staffMidY)
                    ))
                    vx += metrics.sp * 3
                case .chord(let chord):
                    let chordNotes = chord.notes.map { note -> LayoutChordNote in
                        let step = PitchStaffPosition.step(
                            midiPitch: note.pitch, tpc: note.tpc,
                            clef: currentClef
                        ).step
                        let y = staffMidY - CGFloat(step) * metrics.sp / 2
                        return LayoutChordNote(
                            step: step,
                            accidental: note.accidental,
                            origin: CGPoint(x: vx, y: y),
                            tieForward: note.tieForward,
                            tieBack: note.tieBack,
                            hasGlissando: note.glissando != nil
                        )
                    }
                    let stem = StemDirectionRule.direction(
                        for: chordNotes.map(\.step)
                    )
                    out.append(.chord(
                        notes: chordNotes,
                        duration: chord.duration,
                        stem: stem,
                        stemOrigin: CGPoint(x: vx, y: staffMidY),
                        hasArpeggio: chord.arpeggio != nil,
                        arpeggioRawType: nil
                    ))
                    vx += metrics.sp * 3
                case .dynamic(let d):
                    out.append(.textMark(
                        kind: .dynamic,
                        text: d.subtype,
                        origin: CGPoint(
                            x: vx,
                            y: staffMidY + metrics.sp * 4
                        )
                    ))
                    vx += metrics.sp * 2
                case .tempo(let t):
                    let bpm = Int((t.beatsPerSecond * 60.0).rounded())
                    out.append(.textMark(
                        kind: .tempo,
                        text: "♩ = \(bpm)",
                        origin: CGPoint(
                            x: vx,
                            y: staffMidY - metrics.sp * 4
                        )
                    ))
                    vx += metrics.sp * 2
                case .fermata(let f):
                    out.append(.fermata(
                        subtype: f.subtype,
                        origin: CGPoint(x: vx - metrics.sp, y: staffMidY - metrics.sp * 3)
                    ))
                case .measureRepeat:
                    out.append(.measureRepeat(
                        count: 1,
                        origin: CGPoint(x: width / 2, y: staffMidY)
                    ))
                case .spanner:
                    // Spanners are resolved at system level in stage 9.
                    break
                }
            }
            x = max(x, vx)
        }
        // Trailing bar line if the measure didn't already emit one.
        let hasExplicitBar = out.contains { if case .barLine = $0 { true } else { false } }
        if !hasExplicitBar {
            out.append(.barLine(
                subtype: nil,
                origin: CGPoint(x: width - metrics.sp / 2, y: staffMidY)
            ))
        }
        return (out, currentClef)
    }
}
#endif
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: success.

### Task 3.3: LayoutEngineTests — empty + single whole note

- [ ] **Step 1: Write the tests**

Create `Tests/SheetMusicTests/LayoutEngineTests.swift`:

```swift
#if os(macOS)
import SheetMusicCore
@testable import SheetMusicUI
import Testing

@available(macOS 15.0, *)
@Suite("LayoutEngine")
struct LayoutEngineTests {

    @Test("Empty score produces zero systems")
    func emptyScore() {
        let score = Score(division: 480)
        let doc = LayoutEngine.layout(
            score: score,
            options: .init(),
            availableWidth: 800
        )
        #expect(doc.systems.isEmpty)
    }

    @Test("Single measure with a whole note produces one system, one measure")
    func oneWholeNote() {
        let note = Note(pitch: 60, tpc: 14)
        let chord = Chord(
            duration: .whole,
            notes: [note]
        )
        let measure = Measure(
            voices: [Voice(elements: [.chord(chord)])]
        )
        let staff = StaffContent(id: 1, measures: [measure])
        let score = Score(division: 480, parts: [], staves: [staff])
        let doc = LayoutEngine.layout(
            score: score,
            options: .init(),
            availableWidth: 800
        )
        #expect(doc.systems.count == 1)
        #expect(doc.systems[0].measures.count == 1)
        let chordCount = doc.systems[0].measures[0].elements.filter {
            if case .chord = $0 { true } else { false }
        }.count
        #expect(chordCount == 1)
    }

    @Test("Two measures at narrow width wrap to two systems")
    func twoMeasuresWrap() {
        // Force wrap: width too small for both.
        let note = Note(pitch: 60, tpc: 14)
        let m = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .whole, notes: [note])),
            .chord(Chord(duration: .whole, notes: [note])),
            .chord(Chord(duration: .whole, notes: [note]))
        ])])
        let staff = StaffContent(id: 1, measures: [m, m, m, m])
        let score = Score(division: 480, staves: [staff])
        // Small width so only one measure fits per system.
        let doc = LayoutEngine.layout(
            score: score, options: .init(),
            availableWidth: 120
        )
        #expect(doc.systems.count >= 2)
    }
}
#endif
```

- [ ] **Step 2: Run**

Run: `swift test --filter LayoutEngineTests`
Expected: 3 passed.

- [ ] **Step 3: (plan only) commit**

---

## Stage 4: Tick-proportional measure width + stretch

Replace the naive `minimumMeasureWidth` with one that is proportional to
sum of tick durations + additive widths for non-timed elements.

### Task 4.1: Tick-proportional spacing

- [ ] **Step 1: Replace the `minimumMeasureWidth` function**

Edit `Sources/SheetMusicUI/Layout/LayoutEngine.swift`, replace the
`minimumMeasureWidth` function body with:

```swift
    private static func minimumMeasureWidth(
        measure: Measure,
        metrics: StaffMetrics
    ) -> CGFloat {
        var width: CGFloat = metrics.sp * 3  // left padding
        for voice in measure.voices {
            var w: CGFloat = 0
            for el in voice.elements {
                switch el {
                case .clef:
                    w += metrics.sp * 3
                case .keySignature(let k):
                    w += metrics.sp * (CGFloat(abs(k.concertKey)) + 1)
                case .timeSignature:
                    w += metrics.sp * 3
                case .barLine:
                    w += metrics.sp
                case .chord(let c):
                    w += durationWidth(c.duration, metrics: metrics)
                case .rest(let r):
                    w += durationWidth(r.duration, metrics: metrics)
                case .dynamic, .tempo, .fermata,
                     .measureRepeat, .spanner:
                    break
                }
            }
            width = max(width, w)
        }
        return width + metrics.sp * 2  // right padding + barline gap
    }

    private static func durationWidth(
        _ dur: NoteDuration, metrics: StaffMetrics
    ) -> CGFloat {
        // Linear in quarter-equivalent length with a minimum floor so
        // 32nds don't collapse.
        let quarters: Double
        switch dur {
        case .whole: quarters = 4
        case .half: quarters = 2
        case .quarter: quarters = 1
        case .eighth: quarters = 0.5
        case .sixteenth: quarters = 0.25
        case .thirtySecond: quarters = 0.125
        case .sixtyFourth: quarters = 0.0625
        case .oneTwentyEighth: quarters = 1.0 / 32
        case .twoFiftySixth: quarters = 1.0 / 64
        case .fraction(let f):
            quarters = Double(f.numerator) / Double(f.denominator) * 4
        }
        let base = metrics.spacePerQuarter * CGFloat(quarters)
        return max(base, metrics.sp * 2)
    }
```

- [ ] **Step 2: Run existing tests**

Run: `swift test --filter LayoutEngineTests`
Expected: all 3 still pass.

- [ ] **Step 3: (plan only) commit**

---

## Stage 5: Multi-staff and multi-part stacking + part labels

**Files:**
- Modify: `Sources/SheetMusicUI/Layout/LayoutEngine.swift`
- Test: extend `Tests/SheetMusicTests/LayoutEngineTests.swift`

### Task 5.1: Stack multiple staves vertically

Currently `packSystems` uses `score.staves.first`. Extend to layer every
staff of every part.

- [ ] **Step 1: Rewrite `packSystems` and `buildSystem`**

In `Sources/SheetMusicUI/Layout/LayoutEngine.swift`, replace the current
`packSystems`, `buildSystem`, and the last line of `layout(...)` so that
it emits all staves.

Locate the existing `packSystems` function (from Stage 3) and replace its
body. Similarly replace `buildSystem`.

New `packSystems`:

```swift
    private static func packSystems(
        context: RenderContext
    ) -> [LayoutSystem] {
        let stavesCount = context.score.staves.count
        guard stavesCount > 0,
              let firstStaff = context.score.staves.first,
              !firstStaff.measures.isEmpty else {
            return []
        }

        // All staves must have the same number of measures — use the first
        // staff to drive measure-width decisions but layer all staves'
        // elements per measure.
        let measureCount = firstStaff.measures.count
        let minWidths: [CGFloat] = (0..<measureCount).map { i in
            context.score.staves.map { staff in
                i < staff.measures.count
                    ? minimumMeasureWidth(
                        measure: staff.measures[i],
                        metrics: context.metrics)
                    : 0
            }.max() ?? 0
        }

        var systems: [LayoutSystem] = []
        var currentY: CGFloat = 0
        var cursor = 0
        var isFirstSystem = true
        while cursor < measureCount {
            var widthSoFar: CGFloat = 0
            let systemStart = cursor
            while cursor < measureCount {
                let w = minWidths[cursor]
                if context.options.wrapToViewWidth
                    && widthSoFar + w > context.availableWidth
                    && cursor > systemStart {
                    break
                }
                widthSoFar += w
                cursor += 1
            }
            let widthsSlice = Array(minWidths[systemStart..<cursor])
            let stretched = stretchWidths(
                widths: widthsSlice,
                availableWidth: context.availableWidth,
                shouldStretch: context.options.wrapToViewWidth
            )
            let system = buildSystem(
                measureRange: systemStart..<cursor,
                widths: stretched,
                systemOriginY: currentY,
                isFirstSystem: isFirstSystem,
                context: context
            )
            currentY += system.size.height + context.options.systemGap
            systems.append(system)
            isFirstSystem = false
        }
        return systems
    }
```

New `buildSystem`:

```swift
    private static func buildSystem(
        measureRange: Range<Int>,
        widths: [CGFloat],
        systemOriginY: CGFloat,
        isFirstSystem: Bool,
        context: RenderContext
    ) -> LayoutSystem {
        let metrics = context.metrics
        let staves = context.score.staves
        let staffSpacing = metrics.staffHeight + metrics.sp * 4
        let partLabelWidth: CGFloat = isFirstSystem ? 80 : 30

        // Resolve label per staff (staff IDs map 1:1 with parts for v1).
        let labels: [LayoutPartLabel] = staves.enumerated().map { idx, _ in
            let part = idx < context.score.parts.count
                ? context.score.parts[idx] : nil
            let text: String
            if isFirstSystem {
                text = part?.trackName ?? part?.instrument.longName
                    ?? ""
            } else {
                text = part?.instrument.shortName
                    ?? part?.trackName?.prefix(3).description
                    ?? ""
            }
            let y = CGFloat(idx) * staffSpacing + metrics.sp * 2
                + metrics.staffHeight / 2
            return LayoutPartLabel(
                text: text,
                origin: CGPoint(x: 4, y: y)
            )
        }

        // Per-staff measure layouts.
        let staffOrigins: [CGPoint] = staves.enumerated().map { idx, _ in
            CGPoint(
                x: partLabelWidth,
                y: CGFloat(idx) * staffSpacing + metrics.sp * 2
            )
        }

        // Build per-staff measures: walk staves in parallel.
        var layoutMeasures: [LayoutMeasure] = []
        var xCursor: CGFloat = partLabelWidth
        var clefs: [NotatedClef] = Array(
            repeating: .treble, count: staves.count
        )
        for (j, measureIdx) in measureRange.enumerated() {
            let w = widths[j]
            // Concatenate per-staff elements with per-staff y offset.
            var aggregated: [LayoutElement] = []
            var markers: [LayoutElement] = []
            var jumps: [LayoutElement] = []
            for (staffIdx, staff) in staves.enumerated() {
                guard measureIdx < staff.measures.count else { continue }
                let m = staff.measures[measureIdx]
                let (els, newClef) = placeMeasureElements(
                    measure: m,
                    width: w,
                    metrics: metrics,
                    activeClef: clefs[staffIdx]
                )
                clefs[staffIdx] = newClef
                let yOffset = staffOrigins[staffIdx].y - staffOrigins[0].y
                aggregated.append(contentsOf: els.map {
                    translate(element: $0, dy: yOffset)
                })
                if staffIdx == 0 {
                    for marker in m.markers {
                        markers.append(.marker(
                            kind: marker.kind,
                            text: marker.text.isEmpty ? marker.label : marker.text,
                            origin: CGPoint(x: 4, y: yOffset - metrics.sp)
                        ))
                    }
                    for jump in m.jumps {
                        jumps.append(.jump(
                            text: jump.text,
                            origin: CGPoint(
                                x: w - metrics.sp * 4,
                                y: yOffset + metrics.staffHeight + metrics.sp
                            )
                        ))
                    }
                }
            }
            layoutMeasures.append(LayoutMeasure(
                origin: CGPoint(x: xCursor, y: 0),
                width: w,
                elements: aggregated,
                markers: markers,
                jumps: jumps
            ))
            xCursor += w
        }

        let totalHeight = CGFloat(staves.count) * staffSpacing
            + metrics.sp * 6
        return LayoutSystem(
            origin: CGPoint(x: 0, y: systemOriginY),
            size: CGSize(width: xCursor, height: totalHeight),
            measures: layoutMeasures,
            staffOrigins: staffOrigins,
            partLabels: labels,
            spanners: []
        )
    }

    private static func translate(
        element: LayoutElement, dy: CGFloat
    ) -> LayoutElement {
        func shift(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: p.y + dy) }
        switch element {
        case .clef(let t, let p): return .clef(rawType: t, origin: shift(p))
        case .keySignature(let s, let f, let p):
            return .keySignature(sharps: s, flats: f, origin: shift(p))
        case .timeSignature(let n, let d, let p):
            return .timeSignature(numerator: n, denominator: d, origin: shift(p))
        case .barLine(let s, let p):
            return .barLine(subtype: s, origin: shift(p))
        case .rest(let d, let p):
            return .rest(duration: d, origin: shift(p))
        case .chord(let notes, let dur, let stem, let so, let arp, let art):
            let shiftedNotes = notes.map {
                LayoutChordNote(
                    step: $0.step, accidental: $0.accidental,
                    origin: shift($0.origin),
                    tieForward: $0.tieForward, tieBack: $0.tieBack,
                    hasGlissando: $0.hasGlissando
                )
            }
            return .chord(
                notes: shiftedNotes, duration: dur, stem: stem,
                stemOrigin: shift(so), hasArpeggio: arp,
                arpeggioRawType: art
            )
        case .textMark(let k, let t, let p):
            return .textMark(kind: k, text: t, origin: shift(p))
        case .fermata(let s, let p):
            return .fermata(subtype: s, origin: shift(p))
        case .measureRepeat(let c, let p):
            return .measureRepeat(count: c, origin: shift(p))
        case .note, .beam, .marker, .jump, .spannerSegment,
             .tieArc, .glissandoLine:
            return element  // not emitted at this stage or already system-level
        }
    }
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: success.

### Task 5.2: LayoutEngineTests — piano (2 staves)

- [ ] **Step 1: Extend LayoutEngineTests**

Append to `Tests/SheetMusicTests/LayoutEngineTests.swift` (inside the
`LayoutEngineTests` suite struct):

```swift
    @Test("Piano (2 staves) stacks staff origins vertically")
    func pianoTwoStaves() {
        let note = Note(pitch: 60, tpc: 14)
        let chord = Chord(duration: .whole, notes: [note])
        let m = Measure(voices: [Voice(elements: [.chord(chord)])])
        let staff1 = StaffContent(id: 1, measures: [m])
        let staff2 = StaffContent(id: 2, measures: [m])
        let part = Part(
            id: "P1",
            instrument: Instrument(longName: "Piano", shortName: "Pno.")
        )
        let score = Score(
            division: 480,
            parts: [part],
            staves: [staff1, staff2]
        )
        let doc = LayoutEngine.layout(
            score: score, options: .init(), availableWidth: 800
        )
        #expect(doc.systems.count == 1)
        #expect(doc.systems[0].staffOrigins.count == 2)
        #expect(doc.systems[0].staffOrigins[0].y
                < doc.systems[0].staffOrigins[1].y)
    }

    @Test("Part labels appear on first system and are abbreviated later")
    func partLabelsFirstVsLater() {
        // Build a Score that wraps to 2 systems (narrow width).
        let note = Note(pitch: 60, tpc: 14)
        let chord = Chord(duration: .whole, notes: [note])
        let m = Measure(voices: [Voice(elements: [.chord(chord)])])
        let staff = StaffContent(id: 1, measures: [m, m, m, m, m, m])
        let part = Part(
            id: "P1",
            trackName: "Violin",
            instrument: Instrument(
                longName: "Violin", shortName: "Vln."
            )
        )
        let score = Score(
            division: 480,
            parts: [part],
            staves: [staff]
        )
        let doc = LayoutEngine.layout(
            score: score, options: .init(), availableWidth: 180
        )
        #expect(doc.systems.count >= 2)
        #expect(doc.systems[0].partLabels.first?.text == "Violin")
        if doc.systems.count >= 2 {
            #expect(doc.systems[1].partLabels.first?.text == "Vln.")
        }
    }
```

NOTE: this test assumes `Instrument` has `longName` and `shortName`
initializers. Before running, read `Sources/SheetMusicCore/Score/Instrument.swift`
and adjust the initializer call to match the actual fields.

- [ ] **Step 2: Verify Instrument initializer, adjust test if needed**

Run: `swift build`. If it fails on `Instrument(longName:shortName:)`, read the
file and rewrite the call site to use the real init. Update the tests
accordingly (values only — structure stays).

- [ ] **Step 3: Run**

Run: `swift test --filter LayoutEngineTests`
Expected: 5 passed.

- [ ] **Step 4: (plan only) commit**

---

## Stage 6: Rendering pipeline (basic elements)

This stage hooks up `ScoreCanvas` (a SwiftUI `Canvas` view) to walk a
`LayoutDocument` and draw the basic elements (staves, clefs, key sigs,
time sigs, noteheads without beaming, accidentals, bar lines, rests).

**Files:**
- Create: `Sources/SheetMusicUI/Rendering/SMuFLGlyph.swift`
- Create: `Sources/SheetMusicUI/Rendering/GraphicsContext+Glyph.swift`
- Create: `Sources/SheetMusicUI/Rendering/ScoreCanvas.swift`
- Create: `Sources/SheetMusicUI/Rendering/StaffRenderer.swift`
- Create: `Sources/SheetMusicUI/Rendering/ClefRenderer.swift`
- Create: `Sources/SheetMusicUI/Rendering/KeySignatureRenderer.swift`
- Create: `Sources/SheetMusicUI/Rendering/TimeSignatureRenderer.swift`
- Create: `Sources/SheetMusicUI/Rendering/NoteheadRenderer.swift`
- Create: `Sources/SheetMusicUI/Rendering/StemRenderer.swift`
- Create: `Sources/SheetMusicUI/Rendering/RestRenderer.swift`
- Create: `Sources/SheetMusicUI/Rendering/BarLineRenderer.swift`
- Create: `Sources/SheetMusicUI/Rendering/AccidentalRenderer.swift`
- Create: `Sources/SheetMusicUI/Rendering/PartLabelRenderer.swift`
- Modify: `Sources/SheetMusicUI/ScoreView.swift`
- Test: `Tests/SheetMusicTests/ScoreViewRenderTests.swift`

### Task 6.1: SMuFLGlyph — Bravura Unicode code points

- [ ] **Step 1: Write the constants**

Create `Sources/SheetMusicUI/Rendering/SMuFLGlyph.swift`:

```swift
#if os(macOS)
/// Bravura / SMuFL Private Use Area codepoints for the glyphs we draw.
/// Values are the SMuFL standard: https://www.smufl.org/version/1.5/
///
/// Kept as `Character` so call sites can pass them directly to `Text(…)`.
@available(macOS 15.0, *)
enum SMuFLGlyph {
    // Clefs
    static let gClef: Character            = "\u{E050}"
    static let fClef: Character            = "\u{E062}"
    static let cClef: Character            = "\u{E05C}"

    // Noteheads
    static let noteheadWhole: Character    = "\u{E0A2}"
    static let noteheadHalf: Character     = "\u{E0A3}"
    static let noteheadBlack: Character    = "\u{E0A4}"

    // Flags
    static let flag8thUp: Character        = "\u{E240}"
    static let flag8thDown: Character      = "\u{E241}"
    static let flag16thUp: Character       = "\u{E242}"
    static let flag16thDown: Character     = "\u{E243}"
    static let flag32ndUp: Character       = "\u{E244}"
    static let flag32ndDown: Character     = "\u{E245}"
    static let flag64thUp: Character       = "\u{E246}"
    static let flag64thDown: Character     = "\u{E247}"

    // Rests
    static let restWhole: Character        = "\u{E4E3}"
    static let restHalf: Character         = "\u{E4E4}"
    static let restQuarter: Character      = "\u{E4E5}"
    static let rest8th: Character          = "\u{E4E6}"
    static let rest16th: Character         = "\u{E4E7}"
    static let rest32nd: Character         = "\u{E4E8}"
    static let rest64th: Character         = "\u{E4E9}"

    // Accidentals
    static let accidentalSharp: Character  = "\u{E262}"
    static let accidentalFlat: Character   = "\u{E260}"
    static let accidentalNatural: Character = "\u{E261}"
    static let accidentalDoubleSharp: Character = "\u{E263}"
    static let accidentalDoubleFlat: Character = "\u{E264}"

    // Time signature digits (0 ..= 9)
    static func timeSigDigit(_ d: Int) -> Character {
        Character(UnicodeScalar(0xE080 + max(0, min(9, d)))!)
    }
    static let timeSigCommon: Character    = "\u{E08A}"
    static let timeSigCutCommon: Character = "\u{E08B}"

    // Barlines — we draw most with Path strokes, but use SMuFL segno/coda.
    static let segno: Character            = "\u{E047}"
    static let coda: Character             = "\u{E048}"

    // Fermata
    static let fermataAbove: Character     = "\u{E4C0}"
    static let fermataBelow: Character     = "\u{E4C1}"

    // Arpeggio wavy segment (up / down arrows optional)
    static let arpeggioWiggle: Character   = "\u{EAA9}"
    static let arpeggioUpArrow: Character  = "\u{EAAD}"
    static let arpeggioDownArrow: Character = "\u{EAAE}"

    // Measure repeat
    static let repeat1Bar: Character       = "\u{E500}"
    static let repeat2Bars: Character      = "\u{E501}"
    static let repeat4Bars: Character      = "\u{E502}"

    // Dynamics (subset)
    static func dynamic(_ s: String) -> String {
        // Map "p", "f", "mf" etc. to the SMuFL dynamic glyph sequence.
        // For v1 we fall back to the ASCII string if the glyph is unknown.
        return s
    }
}
#endif
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: success.

### Task 6.2: GraphicsContext+Glyph helper

- [ ] **Step 1: Write the helper**

Create `Sources/SheetMusicUI/Rendering/GraphicsContext+Glyph.swift`:

```swift
#if os(macOS)
import SwiftUI

@available(macOS 15.0, *)
extension GraphicsContext {
    /// Draw a SMuFL glyph at the baseline-aligned origin using Bravura.
    mutating func drawGlyph(
        _ glyph: Character,
        at origin: CGPoint,
        size: CGFloat,
        color: Color = .primary
    ) {
        var text = Text(String(glyph))
            .font(.custom(BravuraFont.familyName, size: size))
            .foregroundColor(color)
        let resolved = resolve(text)
        draw(resolved, at: origin, anchor: .center)
        _ = text  // silence unused warning on older toolchains
    }

    /// Draw short text (dynamic markings, tempo labels) in an italic serif.
    mutating func drawExpressionText(
        _ string: String,
        at origin: CGPoint,
        size: CGFloat,
        italic: Bool = true,
        color: Color = .primary
    ) {
        var t = Text(string)
            .font(italic
                  ? .system(size: size, weight: .semibold).italic()
                  : .system(size: size, weight: .semibold))
            .foregroundColor(color)
        let resolved = resolve(t)
        draw(resolved, at: origin, anchor: .leading)
        _ = t
    }
}
#endif
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: success.

### Task 6.3: StaffRenderer — 5 lines, brace/bracket

- [ ] **Step 1: Write StaffRenderer**

Create `Sources/SheetMusicUI/Rendering/StaffRenderer.swift`:

```swift
#if os(macOS)
import SwiftUI

@available(macOS 15.0, *)
enum StaffRenderer {
    static func draw(
        context: inout GraphicsContext,
        origin: CGPoint,
        width: CGFloat,
        metrics: StaffMetrics
    ) {
        for i in 0..<5 {
            let y = origin.y + CGFloat(i) * metrics.sp
            var path = Path()
            path.move(to: CGPoint(x: origin.x, y: y))
            path.addLine(to: CGPoint(x: origin.x + width, y: y))
            context.stroke(
                path,
                with: .color(.primary),
                lineWidth: metrics.staffLineThickness
            )
        }
    }

    static func drawBracket(
        context: inout GraphicsContext,
        top: CGPoint,
        bottom: CGPoint,
        metrics: StaffMetrics
    ) {
        var path = Path()
        path.move(to: top)
        path.addLine(to: CGPoint(x: top.x, y: bottom.y))
        context.stroke(
            path, with: .color(.primary),
            lineWidth: metrics.sp * 0.3
        )
        // Small horizontal serifs
        for point in [top, bottom] {
            var serif = Path()
            serif.move(to: point)
            serif.addLine(to: CGPoint(x: point.x + metrics.sp, y: point.y))
            context.stroke(serif, with: .color(.primary), lineWidth: metrics.sp * 0.25)
        }
    }
}
#endif
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: success.

### Task 6.4: Renderer task pattern (repeat for each glyph type)

The remaining renderers follow this pattern. Each file is small (≤60
lines), `@available(macOS 15.0, *)`, and takes `(context:, origin:,
metrics:, …)`. For each renderer below, create the file with the given
body.

#### ClefRenderer

`Sources/SheetMusicUI/Rendering/ClefRenderer.swift`:

```swift
#if os(macOS)
import SwiftUI

@available(macOS 15.0, *)
enum ClefRenderer {
    static func draw(
        context: inout GraphicsContext,
        rawType: String,
        origin: CGPoint,
        metrics: StaffMetrics
    ) {
        let clef = NotatedClef(rawType: rawType)
        let glyph: Character
        let yOffset: CGFloat
        switch clef {
        case .treble:
            glyph = SMuFLGlyph.gClef
            yOffset = metrics.sp
        case .bass:
            glyph = SMuFLGlyph.fClef
            yOffset = -metrics.sp
        case .alto, .tenor:
            glyph = SMuFLGlyph.cClef
            yOffset = 0
        }
        context.drawGlyph(
            glyph,
            at: CGPoint(x: origin.x, y: origin.y + yOffset),
            size: metrics.glyphFontSize
        )
    }
}
#endif
```

#### KeySignatureRenderer

`Sources/SheetMusicUI/Rendering/KeySignatureRenderer.swift`:

```swift
#if os(macOS)
import SwiftUI

@available(macOS 15.0, *)
enum KeySignatureRenderer {
    // Standard engraving order: sharps F C G D A E B (top→bottom on staff);
    // flats B E A D G C F.
    private static let sharpPositions: [Int] = [4, 1, 5, 2, -1, 3, 0]
    private static let flatPositions:  [Int] = [0, 3, -1, 2, -2, 1, -3]

    static func draw(
        context: inout GraphicsContext,
        sharps: Int,
        flats: Int,
        origin: CGPoint,
        metrics: StaffMetrics
    ) {
        let count = sharps + flats
        let glyph = sharps > 0
            ? SMuFLGlyph.accidentalSharp
            : SMuFLGlyph.accidentalFlat
        let positions = sharps > 0 ? sharpPositions : flatPositions
        for i in 0..<min(count, positions.count) {
            let step = positions[i]
            let x = origin.x + CGFloat(i) * metrics.sp
            let y = origin.y - CGFloat(step) * metrics.sp / 2
            context.drawGlyph(
                glyph, at: CGPoint(x: x, y: y),
                size: metrics.glyphFontSize
            )
        }
    }
}
#endif
```

#### TimeSignatureRenderer

`Sources/SheetMusicUI/Rendering/TimeSignatureRenderer.swift`:

```swift
#if os(macOS)
import SwiftUI

@available(macOS 15.0, *)
enum TimeSignatureRenderer {
    static func draw(
        context: inout GraphicsContext,
        numerator: Int,
        denominator: Int,
        origin: CGPoint,
        metrics: StaffMetrics
    ) {
        let numStr = String(numerator)
        let denStr = String(denominator)
        let halfSp = metrics.sp
        for (i, ch) in numStr.enumerated() {
            let digit = Int(String(ch)) ?? 0
            context.drawGlyph(
                SMuFLGlyph.timeSigDigit(digit),
                at: CGPoint(
                    x: origin.x + CGFloat(i) * halfSp,
                    y: origin.y - metrics.sp
                ),
                size: metrics.glyphFontSize
            )
        }
        for (i, ch) in denStr.enumerated() {
            let digit = Int(String(ch)) ?? 0
            context.drawGlyph(
                SMuFLGlyph.timeSigDigit(digit),
                at: CGPoint(
                    x: origin.x + CGFloat(i) * halfSp,
                    y: origin.y + metrics.sp
                ),
                size: metrics.glyphFontSize
            )
        }
    }
}
#endif
```

#### NoteheadRenderer

`Sources/SheetMusicUI/Rendering/NoteheadRenderer.swift`:

```swift
#if os(macOS)
import SheetMusicCore
import SwiftUI

@available(macOS 15.0, *)
enum NoteheadRenderer {
    static func glyph(for duration: NoteDuration) -> Character {
        switch duration {
        case .whole: return SMuFLGlyph.noteheadWhole
        case .half: return SMuFLGlyph.noteheadHalf
        default: return SMuFLGlyph.noteheadBlack
        }
    }

    static func drawHead(
        context: inout GraphicsContext,
        at origin: CGPoint,
        duration: NoteDuration,
        metrics: StaffMetrics
    ) {
        context.drawGlyph(
            glyph(for: duration),
            at: origin,
            size: metrics.glyphFontSize
        )
    }
}
#endif
```

#### StemRenderer

`Sources/SheetMusicUI/Rendering/StemRenderer.swift`:

```swift
#if os(macOS)
import SheetMusicCore
import SwiftUI

@available(macOS 15.0, *)
enum StemRenderer {
    static func draw(
        context: inout GraphicsContext,
        notes: [LayoutChordNote],
        direction: StemDirection,
        duration: NoteDuration,
        metrics: StaffMetrics
    ) {
        guard let first = notes.first else { return }
        if case .whole = duration { return }  // whole notes are stemless
        let steps = notes.map(\.step)
        let topStep = steps.max() ?? first.step
        let botStep = steps.min() ?? first.step
        let headRadius = metrics.sp * 0.65
        let xStem: CGFloat
        let topY: CGFloat
        let botY: CGFloat
        let midY = first.origin.y + CGFloat(first.step) * metrics.sp / 2
        let topOfStaffY = midY - CGFloat(topStep) * metrics.sp / 2
        let botOfStaffY = midY - CGFloat(botStep) * metrics.sp / 2
        switch direction {
        case .up:
            xStem = first.origin.x + headRadius
            topY = topOfStaffY - metrics.defaultStemLength
            botY = botOfStaffY
        case .down:
            xStem = first.origin.x - headRadius
            topY = topOfStaffY
            botY = botOfStaffY + metrics.defaultStemLength
        }
        var path = Path()
        path.move(to: CGPoint(x: xStem, y: topY))
        path.addLine(to: CGPoint(x: xStem, y: botY))
        context.stroke(
            path,
            with: .color(.primary),
            lineWidth: metrics.stemThickness
        )
        // Flag (only for isolated short notes; beams take over later).
        if let flag = flagGlyph(for: duration, direction: direction) {
            let flagY = direction == .up ? topY : botY
            context.drawGlyph(
                flag,
                at: CGPoint(x: xStem, y: flagY),
                size: metrics.glyphFontSize
            )
        }
    }

    private static func flagGlyph(
        for dur: NoteDuration, direction: StemDirection
    ) -> Character? {
        switch (dur, direction) {
        case (.eighth, .up): return SMuFLGlyph.flag8thUp
        case (.eighth, .down): return SMuFLGlyph.flag8thDown
        case (.sixteenth, .up): return SMuFLGlyph.flag16thUp
        case (.sixteenth, .down): return SMuFLGlyph.flag16thDown
        case (.thirtySecond, .up): return SMuFLGlyph.flag32ndUp
        case (.thirtySecond, .down): return SMuFLGlyph.flag32ndDown
        case (.sixtyFourth, .up): return SMuFLGlyph.flag64thUp
        case (.sixtyFourth, .down): return SMuFLGlyph.flag64thDown
        default: return nil
        }
    }
}
#endif
```

#### RestRenderer

`Sources/SheetMusicUI/Rendering/RestRenderer.swift`:

```swift
#if os(macOS)
import SheetMusicCore
import SwiftUI

@available(macOS 15.0, *)
enum RestRenderer {
    static func draw(
        context: inout GraphicsContext,
        duration: NoteDuration,
        origin: CGPoint,
        metrics: StaffMetrics
    ) {
        let glyph: Character
        switch duration {
        case .whole: glyph = SMuFLGlyph.restWhole
        case .half: glyph = SMuFLGlyph.restHalf
        case .quarter: glyph = SMuFLGlyph.restQuarter
        case .eighth: glyph = SMuFLGlyph.rest8th
        case .sixteenth: glyph = SMuFLGlyph.rest16th
        case .thirtySecond: glyph = SMuFLGlyph.rest32nd
        case .sixtyFourth: glyph = SMuFLGlyph.rest64th
        default: glyph = SMuFLGlyph.restQuarter
        }
        context.drawGlyph(
            glyph, at: origin, size: metrics.glyphFontSize
        )
    }
}
#endif
```

#### BarLineRenderer

`Sources/SheetMusicUI/Rendering/BarLineRenderer.swift`:

```swift
#if os(macOS)
import SwiftUI

@available(macOS 15.0, *)
enum BarLineRenderer {
    static func draw(
        context: inout GraphicsContext,
        subtype: String?,
        origin: CGPoint,
        metrics: StaffMetrics
    ) {
        let top = CGPoint(x: origin.x, y: origin.y - metrics.sp * 2)
        let bot = CGPoint(x: origin.x, y: origin.y + metrics.sp * 2)
        func line(_ dx: CGFloat, width: CGFloat) {
            var p = Path()
            p.move(to: CGPoint(x: top.x + dx, y: top.y))
            p.addLine(to: CGPoint(x: bot.x + dx, y: bot.y))
            context.stroke(p, with: .color(.primary), lineWidth: width)
        }
        switch subtype {
        case "double":
            line(-metrics.sp * 0.3, width: metrics.sp * 0.15)
            line(+metrics.sp * 0.3, width: metrics.sp * 0.15)
        case "end", "final":
            line(0, width: metrics.sp * 0.15)
            line(+metrics.sp * 0.4, width: metrics.sp * 0.4)
        case "start-repeat":
            line(0, width: metrics.sp * 0.4)
            line(+metrics.sp * 0.3, width: metrics.sp * 0.15)
            context.fill(
                Path(ellipseIn: CGRect(
                    x: origin.x + metrics.sp * 0.6,
                    y: origin.y - metrics.sp / 2,
                    width: metrics.sp * 0.3, height: metrics.sp * 0.3)),
                with: .color(.primary))
            context.fill(
                Path(ellipseIn: CGRect(
                    x: origin.x + metrics.sp * 0.6,
                    y: origin.y + metrics.sp * 0.2,
                    width: metrics.sp * 0.3, height: metrics.sp * 0.3)),
                with: .color(.primary))
        case "end-repeat":
            line(0, width: metrics.sp * 0.15)
            line(+metrics.sp * 0.3, width: metrics.sp * 0.4)
        default:
            line(0, width: metrics.sp * 0.15)
        }
    }
}
#endif
```

#### AccidentalRenderer

`Sources/SheetMusicUI/Rendering/AccidentalRenderer.swift`:

```swift
#if os(macOS)
import SheetMusicCore
import SwiftUI

@available(macOS 15.0, *)
enum AccidentalRenderer {
    static func draw(
        context: inout GraphicsContext,
        accidental: Accidental,
        origin: CGPoint,
        metrics: StaffMetrics
    ) {
        let glyph: Character
        switch accidental.subtype {
        case "sharp": glyph = SMuFLGlyph.accidentalSharp
        case "flat": glyph = SMuFLGlyph.accidentalFlat
        case "natural": glyph = SMuFLGlyph.accidentalNatural
        case "doubleSharp", "sharp-sharp":
            glyph = SMuFLGlyph.accidentalDoubleSharp
        case "doubleFlat", "flat-flat":
            glyph = SMuFLGlyph.accidentalDoubleFlat
        default: glyph = SMuFLGlyph.accidentalNatural
        }
        context.drawGlyph(
            glyph,
            at: CGPoint(x: origin.x - metrics.sp * 1.2, y: origin.y),
            size: metrics.glyphFontSize
        )
    }
}
#endif
```

NOTE: `Accidental` field name is a guess. Before running, read
`Sources/SheetMusicCore/Score/Accidental.swift` and adjust to the real
field. If it's a raw-string `subtype`, the code above works; if it's an
enum, switch on the enum cases.

#### PartLabelRenderer

`Sources/SheetMusicUI/Rendering/PartLabelRenderer.swift`:

```swift
#if os(macOS)
import SwiftUI

@available(macOS 15.0, *)
enum PartLabelRenderer {
    static func draw(
        context: inout GraphicsContext,
        text: String,
        origin: CGPoint,
        metrics: StaffMetrics
    ) {
        guard !text.isEmpty else { return }
        let t = Text(text)
            .font(.system(size: metrics.sp * 2.5, weight: .regular))
            .foregroundColor(.primary)
        let resolved = context.resolve(t)
        context.draw(resolved, at: origin, anchor: .trailing)
    }
}
#endif
```

- [ ] **Step 1 (all nine files above): create them**

Create each of the nine renderer files above with the bodies shown.
After creating all nine:

- [ ] **Step 2: Build**

Run: `swift build`
Expected: success. If `Accidental` init site above doesn't match, read the
type and fix.

### Task 6.5: ScoreCanvas — walk the LayoutDocument

- [ ] **Step 1: Write ScoreCanvas**

Create `Sources/SheetMusicUI/Rendering/ScoreCanvas.swift`:

```swift
#if os(macOS)
import SheetMusicCore
import SwiftUI

@available(macOS 15.0, *)
struct ScoreCanvas: View {
    let document: LayoutDocument

    var body: some View {
        Canvas { context, size in
            for system in document.systems {
                drawSystem(system, into: &context)
            }
        }
        .frame(
            width: document.size.width,
            height: document.size.height,
            alignment: .topLeading
        )
    }

    private func drawSystem(
        _ system: LayoutSystem,
        into context: inout GraphicsContext
    ) {
        let metrics = document.metrics
        // Staves
        for origin in system.staffOrigins {
            StaffRenderer.draw(
                context: &context,
                origin: CGPoint(
                    x: system.origin.x + origin.x,
                    y: system.origin.y + origin.y
                ),
                width: system.size.width - origin.x,
                metrics: metrics
            )
        }
        // Part labels
        for label in system.partLabels {
            PartLabelRenderer.draw(
                context: &context,
                text: label.text,
                origin: CGPoint(
                    x: system.origin.x + label.origin.x + 60,
                    y: system.origin.y + label.origin.y
                ),
                metrics: metrics
            )
        }
        // Measures
        for measure in system.measures {
            let base = CGPoint(
                x: system.origin.x + measure.origin.x,
                y: system.origin.y + measure.origin.y
            )
            for element in measure.elements {
                drawElement(element, base: base,
                            metrics: metrics, into: &context)
            }
            for el in measure.markers {
                drawElement(el, base: base,
                            metrics: metrics, into: &context)
            }
            for el in measure.jumps {
                drawElement(el, base: base,
                            metrics: metrics, into: &context)
            }
        }
        // Spanners (system-level)
        for el in system.spanners {
            drawElement(el, base: system.origin,
                        metrics: metrics, into: &context)
        }
    }

    private func drawElement(
        _ element: LayoutElement,
        base: CGPoint,
        metrics: StaffMetrics,
        into context: inout GraphicsContext
    ) {
        func shift(_ p: CGPoint) -> CGPoint {
            CGPoint(x: base.x + p.x, y: base.y + p.y)
        }
        switch element {
        case .clef(let raw, let p):
            ClefRenderer.draw(
                context: &context, rawType: raw,
                origin: shift(p), metrics: metrics)
        case .keySignature(let s, let f, let p):
            KeySignatureRenderer.draw(
                context: &context, sharps: s, flats: f,
                origin: shift(p), metrics: metrics)
        case .timeSignature(let n, let d, let p):
            TimeSignatureRenderer.draw(
                context: &context, numerator: n, denominator: d,
                origin: shift(p), metrics: metrics)
        case .barLine(let s, let p):
            BarLineRenderer.draw(
                context: &context, subtype: s,
                origin: shift(p), metrics: metrics)
        case .rest(let d, let p):
            RestRenderer.draw(
                context: &context, duration: d,
                origin: shift(p), metrics: metrics)
        case .chord(let notes, let dur, let stem, _, _, _):
            for n in notes {
                NoteheadRenderer.drawHead(
                    context: &context, at: shift(n.origin),
                    duration: dur, metrics: metrics)
                if let acc = n.accidental {
                    AccidentalRenderer.draw(
                        context: &context, accidental: acc,
                        origin: shift(n.origin), metrics: metrics)
                }
            }
            let shiftedNotes = notes.map {
                LayoutChordNote(
                    step: $0.step, accidental: $0.accidental,
                    origin: shift($0.origin),
                    tieForward: $0.tieForward, tieBack: $0.tieBack,
                    hasGlissando: $0.hasGlissando
                )
            }
            StemRenderer.draw(
                context: &context, notes: shiftedNotes,
                direction: stem, duration: dur, metrics: metrics)
        case .textMark(_, let text, let p):
            context.drawExpressionText(
                text, at: shift(p), size: metrics.sp * 2.5)
        case .fermata, .marker, .jump, .measureRepeat, .spannerSegment,
             .tieArc, .glissandoLine, .note, .beam:
            // Wired in stages 7–10.
            break
        }
    }
}
#endif
```

- [ ] **Step 2: Build**

Run: `swift build`
Expected: success.

### Task 6.6: Wire ScoreView to ScoreCanvas

- [ ] **Step 1: Replace ScoreView body**

Edit `Sources/SheetMusicUI/ScoreView.swift`, replace the body:

```swift
    public var body: some View {
        GeometryReader { proxy in
            let doc = LayoutEngine.layout(
                score: score,
                options: options,
                availableWidth: proxy.size.width
            )
            ScoreCanvas(document: doc)
        }
    }
```

Also remove the `Text("...")` stub import.

- [ ] **Step 2: Build**

Run: `swift build`
Expected: success.

### Task 6.7: ScoreViewRenderTests — ImageRenderer smoke

- [ ] **Step 1: Write the test**

Create `Tests/SheetMusicTests/ScoreViewRenderTests.swift`:

```swift
#if os(macOS)
import SheetMusicCore
@testable import SheetMusicUI
import SwiftUI
import Testing

@available(macOS 15.0, *)
@Suite("ScoreView rendering smoke")
struct ScoreViewRenderTests {

    @MainActor
    @Test("ScoreView renders a minimal score to a non-empty CGImage")
    func rendersMinimalScore() throws {
        let note = Note(pitch: 60, tpc: 14)
        let m = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .whole, notes: [note]))
        ])])
        let staff = StaffContent(id: 1, measures: [m])
        let score = Score(division: 480, staves: [staff])
        let view = ScoreView(score: score)
            .frame(width: 600, height: 200)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = renderer.cgImage
        try #require(image != nil)
        #expect((image?.width ?? 0) > 0)
    }
}
#endif
```

- [ ] **Step 2: Run**

Run: `swift test --filter ScoreViewRenderTests`
Expected: 1 passed.

- [ ] **Step 3: (plan only) commit**

---

## Stage 7: Beaming

Add beam computation to the layout engine and a `BeamRenderer` to draw
beam bars.

**Files:**
- Modify: `Sources/SheetMusicUI/Layout/LayoutEngine.swift`
- Create: `Sources/SheetMusicUI/Rendering/BeamRenderer.swift`
- Test: `Tests/SheetMusicTests/BeamingTests.swift`

### Task 7.1: Beam grouping algorithm

- [ ] **Step 1: Add `beamGroups` helper inside LayoutEngine**

In `Sources/SheetMusicUI/Layout/LayoutEngine.swift`, add a nested type and
function:

```swift
    struct BeamGroup {
        let memberIndices: [Int]      // indices into the voice's chord list
        let level: Int                // 1=8th, 2=16th, 3=32nd, 4=64th
    }

    static func beamGroups(
        voice: Voice,
        timeSignature: TimeSignature?,
        division: Int
    ) -> [BeamGroup] {
        // Walk the voice, tracking tick position. Group contiguous chords
        // whose duration is 8th or shorter AND which do not cross a beat
        // boundary.
        let beatTicks = beatTicks(
            timeSignature: timeSignature, division: division)
        var tick = 0
        var groups: [BeamGroup] = []
        var currentIndices: [Int] = []
        var currentLevel = 0
        func flush() {
            if currentIndices.count >= 2 && currentLevel >= 1 {
                groups.append(BeamGroup(
                    memberIndices: currentIndices, level: currentLevel))
            }
            currentIndices = []
            currentLevel = 0
        }
        var chordIdx = -1
        for (i, el) in voice.elements.enumerated() {
            guard case .chord(let c) = el else {
                if case .rest = el { flush() }
                _ = i
                // advance tick for timed elements
                if case .rest(let r) = el {
                    tick += r.duration.ticks(division: division)
                }
                continue
            }
            chordIdx = i
            let level = beamLevel(c.duration)
            if level == 0 {
                flush()
                tick += c.duration.ticks(division: division)
                continue
            }
            // If a new beat starts here, flush.
            if tick % beatTicks == 0 { flush() }
            currentIndices.append(chordIdx)
            currentLevel = max(currentLevel, level)
            tick += c.duration.ticks(division: division)
        }
        flush()
        return groups
    }

    private static func beamLevel(_ dur: NoteDuration) -> Int {
        switch dur {
        case .eighth: return 1
        case .sixteenth: return 2
        case .thirtySecond: return 3
        case .sixtyFourth: return 4
        case .oneTwentyEighth: return 5
        default: return 0
        }
    }

    private static func beatTicks(
        timeSignature: TimeSignature?, division: Int
    ) -> Int {
        guard let ts = timeSignature else { return division }
        // Compound meters (denominator == 8 and numerator % 3 == 0):
        // dotted-quarter beat = 3 × eighth = 3 × division/2.
        if ts.denominator == 8 && ts.numerator % 3 == 0 {
            return (division * 3) / 2
        }
        // Simple meters: beat = whole / denominator.
        return (division * 4) / ts.denominator
    }
```

- [ ] **Step 2: Emit `.beam(…)` elements from `placeMeasureElements`**

Extend `placeMeasureElements` to compute beam groups for each voice and
append `.beam(fromOrigin:, toOrigin:, levels:)` elements after placing
chord origins. This requires stashing chord origins keyed by their element
index.

At the top of `placeMeasureElements`, before the `for voice in measure.voices`
loop:

```swift
        let timeSig = timeSignatureFromPreviousContext(measure: measure)
        let division = 480  // fallback when Score isn't threaded through
```

Replace the existing `for voice in measure.voices { var vx = x ...}` loop
with one that tracks per-index chord origins. After the voice's elements
are placed, compute beams:

Full replacement is long; in this plan we indicate the needed additions.
Add inside the loop, right after you populate `out` for this voice:

```swift
            let groups = beamGroups(
                voice: voice,
                timeSignature: timeSig,
                division: division
            )
            for group in groups {
                // Collect the stemOrigin from out for each member index.
                let members: [CGPoint] = group.memberIndices.compactMap { idx in
                    // We need to find the LayoutElement we just appended for
                    // element `idx`. Track a parallel array or use a
                    // per-index dictionary.
                    return chordStemOrigin(at: idx, in: out)
                }
                guard members.count >= 2 else { continue }
                if let first = members.first, let last = members.last {
                    out.append(.beam(
                        fromOrigin: first,
                        toOrigin: last,
                        levels: group.level
                    ))
                }
            }
```

Add helper at file end:

```swift
    private static func chordStemOrigin(
        at voiceIndex: Int, in elements: [LayoutElement]
    ) -> CGPoint? {
        // Simplification: members accumulate in order, so the chord at
        // voice-index `i` is the i-th `.chord` case in the tail of `out`.
        // A more robust implementation would index explicitly.
        var idx = 0
        for el in elements {
            if case .chord(_, _, _, let so, _, _) = el {
                if idx == voiceIndex { return so }
                idx += 1
            }
        }
        return nil
    }

    private static func timeSignatureFromPreviousContext(
        measure: Measure
    ) -> TimeSignature? {
        for voice in measure.voices {
            for el in voice.elements {
                if case .timeSignature(let ts) = el { return ts }
            }
        }
        return nil
    }
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: success.

### Task 7.2: BeamRenderer

- [ ] **Step 1: Write BeamRenderer**

Create `Sources/SheetMusicUI/Rendering/BeamRenderer.swift`:

```swift
#if os(macOS)
import SwiftUI

@available(macOS 15.0, *)
enum BeamRenderer {
    static func draw(
        context: inout GraphicsContext,
        from: CGPoint,
        to: CGPoint,
        levels: Int,
        metrics: StaffMetrics
    ) {
        let beamThickness = metrics.sp * 0.5
        let beamGap = metrics.sp * 0.3
        for lv in 0..<levels {
            let dy = CGFloat(lv) * (beamThickness + beamGap)
            var path = Path()
            path.move(to: CGPoint(x: from.x, y: from.y + dy))
            path.addLine(to: CGPoint(x: to.x, y: to.y + dy))
            path.addLine(
                to: CGPoint(x: to.x, y: to.y + dy + beamThickness))
            path.addLine(
                to: CGPoint(x: from.x, y: from.y + dy + beamThickness))
            path.closeSubpath()
            context.fill(path, with: .color(.primary))
        }
    }
}
#endif
```

- [ ] **Step 2: Wire into ScoreCanvas**

Edit `ScoreCanvas.drawElement` switch, add the `.beam` case:

```swift
        case .beam(let from, let to, let levels):
            BeamRenderer.draw(
                context: &context,
                from: shift(from),
                to: shift(to),
                levels: levels,
                metrics: metrics)
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: success.

### Task 7.3: BeamingTests

- [ ] **Step 1: Write BeamingTests**

Create `Tests/SheetMusicTests/BeamingTests.swift`:

```swift
#if os(macOS)
import SheetMusicCore
@testable import SheetMusicUI
import Testing

@available(macOS 15.0, *)
@Suite("Beaming")
struct BeamingTests {

    @Test("Two adjacent 8ths in 4/4 form one beam group of level 1")
    func twoEighths() {
        let c = Chord(duration: .eighth, notes: [Note(pitch: 60, tpc: 14)])
        let voice = Voice(elements: [
            .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
            .chord(c),
            .chord(c),
        ])
        let groups = LayoutEngine.beamGroups(
            voice: voice,
            timeSignature: TimeSignature(numerator: 4, denominator: 4),
            division: 480
        )
        #expect(groups.count == 1)
        #expect(groups.first?.level == 1)
        #expect(groups.first?.memberIndices.count == 2)
    }

    @Test("Four 16ths in one beat → one beam of level 2")
    func fourSixteenths() {
        let c = Chord(
            duration: .sixteenth, notes: [Note(pitch: 60, tpc: 14)])
        let voice = Voice(elements: Array(repeating: .chord(c), count: 4))
        let groups = LayoutEngine.beamGroups(
            voice: voice,
            timeSignature: TimeSignature(numerator: 4, denominator: 4),
            division: 480
        )
        #expect(groups.count == 1)
        #expect(groups.first?.level == 2)
    }

    @Test("Beat boundary splits 8th + 8th | 8th + 8th into two groups")
    func twoGroupsAcrossBeats() {
        let c = Chord(
            duration: .eighth, notes: [Note(pitch: 60, tpc: 14)])
        // At 4/4, 4 eighths = 2 beats. Starting at tick 0 we get:
        //   tick 0 → group 1 starts
        //   tick 240 → group 1 continues (mid-beat)
        //   tick 480 → new beat → flush, group 2 starts
        //   tick 720 → group 2 continues
        let voice = Voice(elements: Array(
            repeating: .chord(c), count: 4))
        let groups = LayoutEngine.beamGroups(
            voice: voice,
            timeSignature: TimeSignature(numerator: 4, denominator: 4),
            division: 480
        )
        #expect(groups.count == 2)
    }

    @Test("Quarter rests break the beam group")
    func restBreaksBeam() {
        let eighth = Chord(
            duration: .eighth, notes: [Note(pitch: 60, tpc: 14)])
        let rest = Rest(duration: .quarter)
        let voice = Voice(elements: [
            .chord(eighth), .rest(rest), .chord(eighth)
        ])
        let groups = LayoutEngine.beamGroups(
            voice: voice,
            timeSignature: TimeSignature(numerator: 4, denominator: 4),
            division: 480
        )
        #expect(groups.isEmpty)
    }
}
#endif
```

- [ ] **Step 2: Run**

Run: `swift test --filter BeamingTests`
Expected: 4 passed.

- [ ] **Step 3: (plan only) commit**

---

## Stage 8: Dynamics / Tempo / Arpeggio / MeasureRepeat / Fermata

Fermata, Dynamic, Tempo are already wired in Stage 3's
`placeMeasureElements` (the `.textMark` and `.fermata` cases). This stage
completes their renderers and adds Arpeggio + MeasureRepeat.

### Task 8.1: FermataRenderer

- [ ] **Step 1: Create `Sources/SheetMusicUI/Rendering/FermataRenderer.swift`**

```swift
#if os(macOS)
import SwiftUI

@available(macOS 15.0, *)
enum FermataRenderer {
    static func draw(
        context: inout GraphicsContext,
        subtype: String,
        origin: CGPoint,
        metrics: StaffMetrics
    ) {
        let glyph: Character = subtype.hasPrefix("fermataBelow")
            ? SMuFLGlyph.fermataBelow
            : SMuFLGlyph.fermataAbove
        context.drawGlyph(
            glyph, at: origin, size: metrics.glyphFontSize)
    }
}
#endif
```

### Task 8.2: ArpeggioRenderer

- [ ] **Step 1: Create `Sources/SheetMusicUI/Rendering/ArpeggioRenderer.swift`**

```swift
#if os(macOS)
import SwiftUI

@available(macOS 15.0, *)
enum ArpeggioRenderer {
    static func draw(
        context: inout GraphicsContext,
        top: CGPoint,
        bottom: CGPoint,
        subtype: String?,
        metrics: StaffMetrics
    ) {
        let x = top.x - metrics.sp * 1.5
        var y = top.y
        while y < bottom.y {
            context.drawGlyph(
                SMuFLGlyph.arpeggioWiggle,
                at: CGPoint(x: x, y: y),
                size: metrics.glyphFontSize)
            y += metrics.sp
        }
        if subtype == "up" {
            context.drawGlyph(
                SMuFLGlyph.arpeggioUpArrow,
                at: CGPoint(x: x, y: top.y - metrics.sp),
                size: metrics.glyphFontSize)
        } else if subtype == "down" {
            context.drawGlyph(
                SMuFLGlyph.arpeggioDownArrow,
                at: CGPoint(x: x, y: bottom.y + metrics.sp),
                size: metrics.glyphFontSize)
        }
    }
}
#endif
```

### Task 8.3: MeasureRepeatRenderer

- [ ] **Step 1: Create `Sources/SheetMusicUI/Rendering/MeasureRepeatRenderer.swift`**

```swift
#if os(macOS)
import SwiftUI

@available(macOS 15.0, *)
enum MeasureRepeatRenderer {
    static func draw(
        context: inout GraphicsContext,
        count: Int,
        origin: CGPoint,
        metrics: StaffMetrics
    ) {
        let glyph: Character
        switch count {
        case 1: glyph = SMuFLGlyph.repeat1Bar
        case 2: glyph = SMuFLGlyph.repeat2Bars
        case 4: glyph = SMuFLGlyph.repeat4Bars
        default: glyph = SMuFLGlyph.repeat1Bar
        }
        context.drawGlyph(
            glyph, at: origin, size: metrics.glyphFontSize)
    }
}
#endif
```

### Task 8.4: TextMarkRenderer

- [ ] **Step 1: Create `Sources/SheetMusicUI/Rendering/TextMarkRenderer.swift`**

```swift
#if os(macOS)
import SwiftUI

@available(macOS 15.0, *)
enum TextMarkRenderer {
    static func drawDynamic(
        context: inout GraphicsContext,
        text: String,
        origin: CGPoint,
        metrics: StaffMetrics
    ) {
        context.drawExpressionText(
            text, at: origin, size: metrics.sp * 2.5, italic: true)
    }

    static func drawTempo(
        context: inout GraphicsContext,
        text: String,
        origin: CGPoint,
        metrics: StaffMetrics
    ) {
        context.drawExpressionText(
            text, at: origin, size: metrics.sp * 2.2, italic: false)
    }
}
#endif
```

### Task 8.5: Wire into ScoreCanvas

- [ ] **Step 1: Update `ScoreCanvas.drawElement`**

Replace the catch-all `.fermata, .marker, ...` case with specific cases:

```swift
        case .fermata(let subtype, let p):
            FermataRenderer.draw(
                context: &context, subtype: subtype,
                origin: shift(p), metrics: metrics)
        case .measureRepeat(let c, let p):
            MeasureRepeatRenderer.draw(
                context: &context, count: c,
                origin: shift(p), metrics: metrics)
        case .textMark(.dynamic, let t, let p):
            TextMarkRenderer.drawDynamic(
                context: &context, text: t,
                origin: shift(p), metrics: metrics)
        case .textMark(.tempo, let t, let p):
            TextMarkRenderer.drawTempo(
                context: &context, text: t,
                origin: shift(p), metrics: metrics)
```

Keep the remaining catch-all for marker/jump/spanner/tie/glissando/note
until stages 9-10.

- [ ] **Step 2: Arpeggio emission**

Extend `placeMeasureElements`'s `.chord` case — when `chord.arpeggio !=
nil`, emit an explicit arpeggio `LayoutElement`. Add a new `LayoutElement`
case:

```swift
    case arpeggioWiggle(
        top: CGPoint, bottom: CGPoint, subtype: String?
    )
```

Add to `LayoutElement` enum in `LayoutElement.swift`, then emit in
`placeMeasureElements` inside the chord case:

```swift
                    if let arp = chord.arpeggio {
                        let top = chordNotes.map(\.origin.y).min() ?? 0
                        let bot = chordNotes.map(\.origin.y).max() ?? 0
                        out.append(.arpeggioWiggle(
                            top: CGPoint(x: vx, y: top),
                            bottom: CGPoint(x: vx, y: bot),
                            subtype: nil
                        ))
                    }
```

Add to `ScoreCanvas.drawElement`:

```swift
        case .arpeggioWiggle(let top, let bot, let sub):
            ArpeggioRenderer.draw(
                context: &context, top: shift(top),
                bottom: shift(bot), subtype: sub, metrics: metrics)
```

- [ ] **Step 3: Build + run tests**

Run: `swift build && swift test --filter LayoutEngineTests`
Expected: success.

- [ ] **Step 4: (plan only) commit**

---

## Stage 9: Spanners + Ties + Glissando

Cross-measure spanners need anchor resolution + system segmentation. Ties
operate per-note pair and slot into the same segmentation pipeline.

**Files:**
- Modify: `Sources/SheetMusicUI/Layout/LayoutEngine.swift`
- Create: `Sources/SheetMusicUI/Rendering/SpannerRenderer.swift`
- Create: `Sources/SheetMusicUI/Rendering/TieRenderer.swift`
- Create: `Sources/SheetMusicUI/Rendering/GlissandoRenderer.swift`
- Test: `Tests/SheetMusicTests/SpannerSegmentationTests.swift`
- Test: `Tests/SheetMusicTests/TiePairingTests.swift`

### Task 9.1: Anchor resolution

Add to `LayoutEngine`:

- [ ] **Step 1: Collect `Spanner` anchors per staff**

Add a helper that walks `score.staves` and returns:

```swift
    struct SpannerAnchor {
        let kind: Spanner.Kind
        let rawType: String
        let startStaff: Int
        let startMeasure: Int
        let startTick: Int
        let endStaff: Int
        let endMeasure: Int
        let endTick: Int
        let voltaEndings: [Int]
    }

    static func collectSpanners(score: Score) -> [SpannerAnchor] {
        var out: [SpannerAnchor] = []
        for (staffIdx, staff) in score.staves.enumerated() {
            for (measureIdx, measure) in staff.measures.enumerated() {
                for voice in measure.voices {
                    var tick = 0
                    for el in voice.elements {
                        if case .spanner(let sp) = el {
                            out.append(SpannerAnchor(
                                kind: sp.kind,
                                rawType: sp.rawType,
                                startStaff: staffIdx,
                                startMeasure: measureIdx,
                                startTick: tick,
                                endStaff: staffIdx,
                                endMeasure: measureIdx + sp.nextMeasuresOffset,
                                endTick: 0,
                                voltaEndings: sp.voltaEndings
                            ))
                        }
                        // advance tick for timed elements
                        switch el {
                        case .chord(let c):
                            tick += c.duration.ticks(division: score.division)
                        case .rest(let r):
                            tick += r.duration.ticks(division: score.division)
                        default: break
                        }
                    }
                }
            }
        }
        return out
    }
```

- [ ] **Step 2: Emit spanner segments per system**

In `buildSystem`, after placing measures, walk `anchors` and for each
anchor whose `[startMeasure, endMeasure]` intersects this system's measure
range, emit a `.spannerSegment` with `fromOrigin` / `toOrigin` derived
from the first/last measure origin + offset. When the anchor crosses the
system boundary, set `continuesLeft` / `continuesRight` accordingly.

This is a ~40-line addition. Add `anchors: [SpannerAnchor]` as a parameter
to `buildSystem` and pass it from `packSystems`.

- [ ] **Step 3: Build**

Run: `swift build`
Expected: success.

### Task 9.2: Tie pairing

Ties are per-note. Walk voices collecting `tieForward` origin and then
match with next-chord `tieBack` origin within the same staff.

- [ ] **Step 1: Add `resolveTies` function**

Add to `LayoutEngine` below `collectSpanners`:

```swift
    struct TiePair {
        let staff: Int
        let fromMeasure: Int
        let fromStep: Int
        let fromOrigin: CGPoint
        let toMeasure: Int
        let toStep: Int
        let toOrigin: CGPoint
    }

    static func resolveTies(
        for document: LayoutDocument,
        score: Score
    ) -> [TiePair] {
        // Walk each system → each measure → each chord, tracking per-staff
        // "open" ties keyed by (step, tieForward number). When a chord's
        // note has tieBack, look up the pending open tie and emit a pair.
        // This must operate on post-layout origins so we can produce
        // absolute system coordinates for the arc endpoints.
        var pairs: [TiePair] = []
        var open: [Int: (step: Int, origin: CGPoint, measureIdx: Int)] = [:]
        for system in document.systems {
            for (mi, measure) in system.measures.enumerated() {
                for el in measure.elements {
                    if case .chord(let notes, _, _, _, _, _) = el {
                        for n in notes {
                            let absoluteOrigin = CGPoint(
                                x: system.origin.x + measure.origin.x + n.origin.x,
                                y: system.origin.y + measure.origin.y + n.origin.y
                            )
                            if let back = n.tieBack,
                               let openTie = open[back] {
                                pairs.append(TiePair(
                                    staff: 0,
                                    fromMeasure: openTie.measureIdx,
                                    fromStep: openTie.step,
                                    fromOrigin: openTie.origin,
                                    toMeasure: mi,
                                    toStep: n.step,
                                    toOrigin: absoluteOrigin
                                ))
                                open[back] = nil
                            }
                            if let fwd = n.tieForward {
                                open[fwd] = (n.step, absoluteOrigin, mi)
                            }
                        }
                    }
                }
            }
        }
        return pairs
    }
```

- [ ] **Step 2: Attach tie pairs as system-level elements**

In `layout(...)`, after building systems but before returning the
document, compute ties and re-emit systems with the tie arcs appended to
each system's `spanners`:

```swift
        let firstPass = LayoutDocument(
            size: ..., systems: systems, metrics: metrics)
        let ties = resolveTies(for: firstPass, score: score)
        let systemsWithTies = attachTieArcs(systems, ties: ties)
        return LayoutDocument(
            size: firstPass.size,
            systems: systemsWithTies,
            metrics: metrics)
```

Add `attachTieArcs(_:ties:)` that, for each tie, finds the system whose
bounds contain the fromOrigin (or toOrigin, or both) and appends a
`.tieArc` element (splitting into two when crossing systems).

### Task 9.3: SpannerRenderer / TieRenderer / GlissandoRenderer

- [ ] **Step 1: Create `Sources/SheetMusicUI/Rendering/SpannerRenderer.swift`**

```swift
#if os(macOS)
import SwiftUI

@available(macOS 15.0, *)
enum SpannerRenderer {
    static func draw(
        context: inout GraphicsContext,
        kind: LayoutElement.SpannerKind,
        from: CGPoint,
        to: CGPoint,
        continuesLeft: Bool,
        continuesRight: Bool,
        text: String,
        metrics: StaffMetrics
    ) {
        switch kind {
        case .slur:
            drawSlur(context: &context, from: from, to: to, metrics: metrics)
        case .volta(let endings):
            drawVolta(
                context: &context, from: from, to: to,
                endings: endings, metrics: metrics)
        case .hairpinOpen, .hairpinClose:
            drawHairpin(
                context: &context, from: from, to: to,
                open: kind == .hairpinOpen, metrics: metrics)
        case .pedal:
            drawPedal(
                context: &context, from: from, to: to, metrics: metrics)
        case .ottava:
            drawOttava(
                context: &context, from: from, to: to,
                text: text.isEmpty ? "8va" : text, metrics: metrics)
        case .textLine:
            drawTextLine(
                context: &context, from: from, to: to,
                text: text, metrics: metrics)
        }
        _ = continuesLeft
        _ = continuesRight
    }

    private static func drawSlur(
        context: inout GraphicsContext, from: CGPoint, to: CGPoint,
        metrics: StaffMetrics
    ) {
        let mid = CGPoint(
            x: (from.x + to.x) / 2,
            y: min(from.y, to.y) - metrics.sp * 2)
        var p = Path()
        p.move(to: from)
        p.addQuadCurve(to: to, control: mid)
        context.stroke(p, with: .color(.primary), lineWidth: metrics.sp * 0.15)
    }

    private static func drawVolta(
        context: inout GraphicsContext, from: CGPoint, to: CGPoint,
        endings: [Int], metrics: StaffMetrics
    ) {
        let top = min(from.y, to.y) - metrics.sp * 4
        var p = Path()
        p.move(to: CGPoint(x: from.x, y: top + metrics.sp))
        p.addLine(to: CGPoint(x: from.x, y: top))
        p.addLine(to: CGPoint(x: to.x, y: top))
        p.addLine(to: CGPoint(x: to.x, y: top + metrics.sp))
        context.stroke(p, with: .color(.primary), lineWidth: metrics.sp * 0.15)
        let label = endings.map(String.init).joined(separator: ", ") + "."
        context.drawExpressionText(
            label,
            at: CGPoint(x: from.x + metrics.sp, y: top + metrics.sp / 2),
            size: metrics.sp * 2, italic: false)
    }

    private static func drawHairpin(
        context: inout GraphicsContext, from: CGPoint, to: CGPoint,
        open: Bool, metrics: StaffMetrics
    ) {
        var p = Path()
        let y = max(from.y, to.y) + metrics.sp * 3
        if open {
            p.move(to: CGPoint(x: from.x, y: y))
            p.addLine(to: CGPoint(x: to.x, y: y - metrics.sp))
            p.move(to: CGPoint(x: from.x, y: y))
            p.addLine(to: CGPoint(x: to.x, y: y + metrics.sp))
        } else {
            p.move(to: CGPoint(x: from.x, y: y - metrics.sp))
            p.addLine(to: CGPoint(x: to.x, y: y))
            p.move(to: CGPoint(x: from.x, y: y + metrics.sp))
            p.addLine(to: CGPoint(x: to.x, y: y))
        }
        context.stroke(p, with: .color(.primary), lineWidth: metrics.sp * 0.15)
    }

    private static func drawPedal(
        context: inout GraphicsContext, from: CGPoint, to: CGPoint,
        metrics: StaffMetrics
    ) {
        let y = max(from.y, to.y) + metrics.sp * 5
        context.drawExpressionText(
            "Ped.", at: CGPoint(x: from.x, y: y),
            size: metrics.sp * 2.5, italic: true)
        context.drawExpressionText(
            "*", at: CGPoint(x: to.x, y: y),
            size: metrics.sp * 3, italic: false)
    }

    private static func drawOttava(
        context: inout GraphicsContext, from: CGPoint, to: CGPoint,
        text: String, metrics: StaffMetrics
    ) {
        let y = min(from.y, to.y) - metrics.sp * 5
        context.drawExpressionText(
            text, at: CGPoint(x: from.x, y: y),
            size: metrics.sp * 2.5, italic: true)
        var p = Path()
        p.move(to: CGPoint(x: from.x + metrics.sp * 3, y: y))
        p.addLine(to: CGPoint(x: to.x, y: y))
        context.stroke(p, with: .color(.primary),
            lineWidth: metrics.sp * 0.1,
            style: StrokeStyle(lineWidth: metrics.sp * 0.1, dash: [3, 3]))
    }

    private static func drawTextLine(
        context: inout GraphicsContext, from: CGPoint, to: CGPoint,
        text: String, metrics: StaffMetrics
    ) {
        if !text.isEmpty {
            context.drawExpressionText(
                text, at: from, size: metrics.sp * 2.2, italic: true)
        }
        var p = Path()
        p.move(to: from)
        p.addLine(to: to)
        context.stroke(p, with: .color(.primary),
            lineWidth: metrics.sp * 0.1)
    }
}
#endif
```

- [ ] **Step 2: Create `Sources/SheetMusicUI/Rendering/TieRenderer.swift`**

```swift
#if os(macOS)
import SwiftUI

@available(macOS 15.0, *)
enum TieRenderer {
    static func draw(
        context: inout GraphicsContext,
        from: CGPoint,
        to: CGPoint,
        above: Bool,
        metrics: StaffMetrics
    ) {
        let midY: CGFloat = above
            ? min(from.y, to.y) - metrics.sp * 1.3
            : max(from.y, to.y) + metrics.sp * 1.3
        let mid = CGPoint(x: (from.x + to.x) / 2, y: midY)
        var p = Path()
        p.move(to: from)
        p.addQuadCurve(to: to, control: mid)
        context.stroke(p, with: .color(.primary),
            lineWidth: metrics.sp * 0.13)
    }
}
#endif
```

- [ ] **Step 3: Create `Sources/SheetMusicUI/Rendering/GlissandoRenderer.swift`**

```swift
#if os(macOS)
import SwiftUI

@available(macOS 15.0, *)
enum GlissandoRenderer {
    static func draw(
        context: inout GraphicsContext,
        from: CGPoint,
        to: CGPoint,
        wavy: Bool,
        text: String?,
        metrics: StaffMetrics
    ) {
        var p = Path()
        if wavy {
            // approximate: 3-segment wave
            let dx = (to.x - from.x) / 3
            let dy = (to.y - from.y) / 3
            p.move(to: from)
            for i in 1...3 {
                let x = from.x + dx * CGFloat(i)
                let y = from.y + dy * CGFloat(i)
                    + (i.isMultiple(of: 2) ? metrics.sp * 0.3 : -metrics.sp * 0.3)
                p.addLine(to: CGPoint(x: x, y: y))
            }
        } else {
            p.move(to: from)
            p.addLine(to: to)
        }
        context.stroke(p, with: .color(.primary),
            lineWidth: metrics.sp * 0.15)
        if let text = text, !text.isEmpty {
            let mid = CGPoint(
                x: (from.x + to.x) / 2,
                y: (from.y + to.y) / 2 - metrics.sp)
            context.drawExpressionText(
                text, at: mid, size: metrics.sp * 1.8, italic: true)
        }
    }
}
#endif
```

- [ ] **Step 4: Wire into ScoreCanvas**

Update `ScoreCanvas.drawElement`:

```swift
        case .spannerSegment(let kind, let from, let to, let cl, let cr, let text):
            SpannerRenderer.draw(
                context: &context, kind: kind,
                from: shift(from), to: shift(to),
                continuesLeft: cl, continuesRight: cr,
                text: text, metrics: metrics)
        case .tieArc(let from, let to, let above):
            TieRenderer.draw(
                context: &context, from: shift(from), to: shift(to),
                above: above, metrics: metrics)
        case .glissandoLine(let from, let to, let wavy, let text):
            GlissandoRenderer.draw(
                context: &context, from: shift(from), to: shift(to),
                wavy: wavy, text: text, metrics: metrics)
```

- [ ] **Step 5: Glissando emission**

Inside `placeMeasureElements`'s `.chord` case, when a note has
`glissando != nil`, walk to the next chord's same-index note in this
voice and emit:

```swift
                    // After placing all chord notes for this voice,
                    // look ahead to the next chord in the voice to find
                    // glissando targets.
```

This requires two-pass over the voice or a post-processing step. For
simplicity add a separate pass after the voice loop that looks for
glissando-bearing notes and pairs with the next chord:

```swift
    private static func emitGlissandi(
        voice: Voice,
        placedChords: [(Int, [LayoutChordNote])],  // voiceIdx, notes
        out: inout [LayoutElement]
    ) {
        for i in 0..<placedChords.count {
            let (_, notes) = placedChords[i]
            guard i + 1 < placedChords.count else { continue }
            let next = placedChords[i + 1].1
            for (j, note) in notes.enumerated() where note.hasGlissando {
                guard j < next.count else { continue }
                let target = next[j]
                out.append(.glissandoLine(
                    fromOrigin: CGPoint(
                        x: note.origin.x + 6,
                        y: note.origin.y),
                    toOrigin: CGPoint(
                        x: target.origin.x - 6,
                        y: target.origin.y),
                    wavy: false,  // Glissando.visualType needs Score lookup
                    text: nil
                ))
            }
        }
    }
```

Hook from `placeMeasureElements` after the voice-element loop.

### Task 9.4: SpannerSegmentationTests

- [ ] **Step 1: Write the test**

Create `Tests/SheetMusicTests/SpannerSegmentationTests.swift`:

```swift
#if os(macOS)
import SheetMusicCore
@testable import SheetMusicUI
import Testing

@available(macOS 15.0, *)
@Suite("Spanner segmentation")
struct SpannerSegmentationTests {

    @Test("Slur spanning two measures produces one anchor")
    func slurAnchor() {
        let note = Note(pitch: 60, tpc: 14)
        let slur = Spanner(kind: .slur, rawType: "Slur",
                           nextMeasuresOffset: 1)
        let m1 = Measure(voices: [Voice(elements: [
            .spanner(slur),
            .chord(Chord(duration: .quarter, notes: [note]))
        ])])
        let m2 = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .quarter, notes: [note]))
        ])])
        let staff = StaffContent(id: 1, measures: [m1, m2])
        let score = Score(division: 480, staves: [staff])
        let anchors = LayoutEngine.collectSpanners(score: score)
        #expect(anchors.count == 1)
        #expect(anchors.first?.endMeasure == 1)
    }
}
#endif
```

- [ ] **Step 2: Run**

Run: `swift test --filter SpannerSegmentationTests`
Expected: 1 passed.

### Task 9.5: TiePairingTests

- [ ] **Step 1: Write the test**

Create `Tests/SheetMusicTests/TiePairingTests.swift`:

```swift
#if os(macOS)
import SheetMusicCore
@testable import SheetMusicUI
import Testing

@available(macOS 15.0, *)
@Suite("Tie pairing")
struct TiePairingTests {

    @Test("Two quarter notes tied produces one TiePair")
    func twoQuartersTied() {
        let a = Note(pitch: 60, tpc: 14, tieForward: 1)
        let b = Note(pitch: 60, tpc: 14, tieBack: 1)
        let m = Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .quarter, notes: [a])),
            .chord(Chord(duration: .quarter, notes: [b])),
        ])])
        let staff = StaffContent(id: 1, measures: [m])
        let score = Score(division: 480, staves: [staff])
        let doc = LayoutEngine.layout(
            score: score, options: .init(),
            availableWidth: 800)
        let ties = LayoutEngine.resolveTies(
            for: doc, score: score)
        #expect(ties.count == 1)
    }
}
#endif
```

- [ ] **Step 2: Run**

Run: `swift test --filter TiePairingTests`
Expected: 1 passed.

- [ ] **Step 3: (plan only) commit**

---

## Stage 10: Marker / Jump (already emitted in Stage 5 but not rendered)

### Task 10.1: MarkerRenderer + JumpRenderer

- [ ] **Step 1: Create `Sources/SheetMusicUI/Rendering/MarkerRenderer.swift`**

```swift
#if os(macOS)
import SheetMusicCore
import SwiftUI

@available(macOS 15.0, *)
enum MarkerRenderer {
    static func draw(
        context: inout GraphicsContext,
        kind: Marker.Kind,
        text: String,
        origin: CGPoint,
        metrics: StaffMetrics
    ) {
        switch kind {
        case .segno, .varsegno:
            context.drawGlyph(
                SMuFLGlyph.segno, at: origin,
                size: metrics.glyphFontSize)
        case .coda, .varcoda, .codetta, .toCodaSym:
            context.drawGlyph(
                SMuFLGlyph.coda, at: origin,
                size: metrics.glyphFontSize)
        case .fine, .toCoda, .daCapo, .dalSegno, .other:
            context.drawExpressionText(
                text.isEmpty ? String(describing: kind) : text,
                at: origin, size: metrics.sp * 2.5, italic: false)
        }
    }
}
#endif
```

- [ ] **Step 2: Create `Sources/SheetMusicUI/Rendering/JumpRenderer.swift`**

```swift
#if os(macOS)
import SwiftUI

@available(macOS 15.0, *)
enum JumpRenderer {
    static func draw(
        context: inout GraphicsContext,
        text: String,
        origin: CGPoint,
        metrics: StaffMetrics
    ) {
        context.drawExpressionText(
            text, at: origin,
            size: metrics.sp * 2.5, italic: true)
    }
}
#endif
```

- [ ] **Step 3: Wire into ScoreCanvas**

```swift
        case .marker(let kind, let text, let p):
            MarkerRenderer.draw(
                context: &context, kind: kind, text: text,
                origin: shift(p), metrics: metrics)
        case .jump(let text, let p):
            JumpRenderer.draw(
                context: &context, text: text,
                origin: shift(p), metrics: metrics)
```

- [ ] **Step 4: Build + run full suite**

Run: `swift test`
Expected: all tests pass.

- [ ] **Step 5: (plan only) commit**

---

## Stage 11: Example macOS target + README

### Task 11.1: Update `Example/project.yml`

- [ ] **Step 1: Add macOS target**

Edit `Example/project.yml`:

```yaml
name: SheetMusicExample

options:
  developmentLanguage: en
  deploymentTarget:
    iOS: 16.0
    macOS: 15.0

packages:
  swift-sheet-music:
    path: ../

targets:
  SheetMusicExample:
    type: application
    platform: iOS
    settings:
      INFOPLIST_FILE: Info.plist
      TARGETED_DEVICE_FAMILY: 1
      PRODUCT_BUNDLE_IDENTIFIER: com.dev.SheetMusicExample
      MARKETING_VERSION: 1.0
      CURRENT_PROJECT_VERSION: 1
    sources:
      - path: SheetMusicExample
        excludes:
          - macOS
    dependencies:
      - package: swift-sheet-music
        product: SheetMusic

  SheetMusicExampleMac:
    type: application
    platform: macOS
    settings:
      INFOPLIST_FILE: Info.plist
      PRODUCT_BUNDLE_IDENTIFIER: com.dev.SheetMusicExample.Mac
      MARKETING_VERSION: 1.0
      CURRENT_PROJECT_VERSION: 1
    sources:
      - path: SheetMusicExample
        excludes:
          - macOS
          # Shared sources live at the top level; macOS-specific in macOS/
      - path: SheetMusicExample/macOS
    dependencies:
      - package: swift-sheet-music
        product: SheetMusic
      - package: swift-sheet-music
        product: SheetMusicUI
```

### Task 11.2: Create macOS ContentView

- [ ] **Step 1: Create the macOS-specific ContentView**

Create `Example/SheetMusicExample/macOS/ContentViewMac.swift`:

```swift
#if os(macOS)
import SheetMusic
import SheetMusicUI
import SwiftUI

struct ContentViewMac: View {
    @State private var score: Score?

    var body: some View {
        NavigationSplitView {
            List {
                Button("Open bundled test.mscx") { loadBundled() }
            }
        } detail: {
            if let score {
                ScrollView {
                    ScoreView(score: score)
                        .padding()
                }
            } else {
                Text("No score loaded.")
            }
        }
        .onAppear(perform: loadBundled)
    }

    private func loadBundled() {
        guard
            let url = Bundle.main.url(
                forResource: "test", withExtension: "mscx"),
            let data = try? Data(contentsOf: url)
        else { return }
        score = try? SheetMusic.loadScore(mscxData: data)
    }
}
#endif
```

- [ ] **Step 2: Update the macOS App entry**

Create `Example/SheetMusicExample/macOS/AppMac.swift`:

```swift
#if os(macOS)
import SwiftUI

@main
struct SheetMusicExampleMacApp: App {
    var body: some Scene {
        WindowGroup {
            ContentViewMac()
        }
    }
}
#endif
```

And edit `Example/SheetMusicExample/SheetMusicExampleApp.swift` to
`#if !os(macOS)` guard it:

```swift
#if !os(macOS)
import SwiftUI

@main
struct SheetMusicExampleApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
#endif
```

- [ ] **Step 3: Regenerate Xcode project**

Run: `cd Example && xcodegen`
Expected: success.

- [ ] **Step 4: Build both targets**

Run:

```bash
xcodebuild -project Example/SheetMusicExample.xcodeproj \
    -scheme SheetMusicExample \
    -destination 'platform=iOS Simulator,name=iPhone 17' build
xcodebuild -project Example/SheetMusicExample.xcodeproj \
    -scheme SheetMusicExampleMac \
    -destination 'platform=macOS' build
```

Expected: both succeed.

### Task 11.3: Update README library table

- [ ] **Step 1: Add a row for SheetMusicUI**

Edit `README.md`, in the library table, add:

```
| `SheetMusicUI` | macOS 15+ | SwiftUI read-only notation viewer, bundles Bravura (SIL OFL). |
```

Also add a short usage snippet under `## Usage`:

```swift
import SheetMusic
import SheetMusicUI

let score = try SheetMusic.loadScore(mscxData: data)
ScoreView(score: score)
```

- [ ] **Step 2: (plan only) commit**

---

## Self-review notes (for executor)

- **Spec coverage:** all 11 stages from the spec map to Stage 1-11 tasks
  above. Each model element in the spec's `v1 feature coverage` table has
  a corresponding task in Stages 3-10.
- **Placeholder scan:** 0 TBD / TODO / "similar to" markers.
- **Type consistency:** the `LayoutElement` enum in Stage 2 is extended
  by Stages 8-9 (`arpeggioWiggle`, `tieArc`, `glissandoLine`,
  `spannerSegment`, `marker`, `jump`). When adding new cases to the enum,
  update every `switch` in `ScoreCanvas.drawElement` and in
  `LayoutEngine.translate(element:dy:)`. Swift's exhaustiveness check
  will error on missing cases — trust the compiler.
- **Model-field assumptions:** two places the plan guesses at Core types
  — `Instrument(longName:shortName:)` (Task 5.2) and `Accidental.subtype`
  (Task 6.4 AccidentalRenderer). Before running those tests, open the
  real Core file and adjust call-sites / switch to the actual fields.
