# Engraving Extraction — Design

Date: 2026-05-19
Status: Draft (no implementation yet)

## Goal

Extract platform-agnostic engraving knowledge (SMuFL codepoint tables,
clef Y offsets, key-signature step orders, time-signature digit
centering, stem geometry, tie/slur control-point math) out of
`SheetMusicUI` (Apple-only) and into `SheetMusicLayout` (cross-platform),
so a single source of truth drives both the SwiftUI renderers and the
Android `LayoutBridge` glyph emission.

## Background

`SheetMusicLayout` is a pure-geometry, Foundation-only target. It
produces a `LayoutDocument` of typed `LayoutElement`s — clef with
`rawType: String` and `origin: CGPoint`, key signature with sharp/flat
counts, etc. — but it stops short of mapping those typed values to
SMuFL codepoints or exact glyph anchor positions.

The glyph mapping currently lives in `SheetMusicUI` renderers:

| Concept | File |
|---|---|
| `NotatedClef` → `(codepoint, yOffset)` | `Sources/SheetMusicUI/Rendering/ClefRenderer.swift` |
| `sharpSteps` / `flatSteps` (key sig staff steps) | `Sources/SheetMusicUI/Rendering/KeySignatureRenderer.swift` |
| Time-signature digit centering math | `Sources/SheetMusicUI/Rendering/TimeSignatureRenderer.swift` |
| Stem attach-Dx, beamY logic, default stem length application | `Sources/SheetMusicUI/Rendering/StemRenderer.swift` |
| SMuFL Unicode constants (`gClef`, `fClef`, `cClef`, accidentals, time-sig digits, …) | `Sources/SheetMusicUI/Rendering/SMuFLGlyph.swift` |

`SheetMusicUI` depends on SwiftUI / CoreText / CoreGraphics and is
gated to Apple platforms. As a result the engraving data inside it is
**not reachable from Android**.

The Android pipeline (`Sources/SheetMusicAndroidJNI/LayoutBridge.swift`)
needs the same mapping to turn `LayoutDocument` into the
`DrawProgram` byte stream consumed by the Compose `ScoreCanvas`. The
working `worktree-android-compose-example` branch currently
**re-implements those mappings inline** in `LayoutBridge.swift`. That
is the duplication this spec eliminates.

## Problem (concrete duplication)

Side-by-side excerpt of the current state. Each row is a piece of
engraving data that exists in two places and must be kept in lockstep
by convention only.

| What | `SheetMusicUI` | `SheetMusicAndroidJNI/LayoutBridge.swift` |
|---|---|---|
| `gClef = 0xE050`, `fClef = 0xE062`, … | `SMuFLGlyph.swift` (`Character`) | `enum SMuFL { static let gClef: UInt32 = 0xE050 }` |
| Treble clef yOffset = `+sp`, alto = `0`, tenor = `−sp`, … | `ClefRenderer.draw` `switch clef` | `clefGlyph(_:)` `switch clef` |
| Sharp step order `[4, 1, 5, 2, -1, 3, 0]` | `KeySignatureRenderer.sharpSteps` | `LayoutBridge.sharpSteps` |
| Flat step order `[0, 3, -1, 2, -2, 1, -3]` | `KeySignatureRenderer.flatSteps` | `LayoutBridge.flatSteps` |
| Digit advance `1.4 sp`, row Y = `±sp` from middle | `TimeSignatureRenderer.draw` | `emitTimeSigRow` + inline math |
| `stemAttachDx = 0.59 * sp` | `StemRenderer.draw` | `emitStem` |
| BeamY substitution rule | `StemRenderer.draw` | `emitStem` |

Whenever a SMuFL glyph mapping or staff-step table changes, BOTH files
must be updated. There is no compile-time check that catches drift.

## Proposed structure

Add a new submodule under `SheetMusicLayout` named `Engraving`:

```
Sources/SheetMusicLayout/
  Engraving/
    SMuFLCodepoints.swift     // SMuFL Unicode constants (UInt32)
    ClefGlyph.swift           // NotatedClef → (codepoint, yOffsetSp)
    KeySignatureSteps.swift   // sharpSteps / flatSteps + step → Y helper
    TimeSignatureLayout.swift // digit centering / row Y helpers
    StemGeometry.swift        // attach-Dx, beamY substitution, default stem
    TieArcGeometry.swift      // cubic Bezier control points for tie/slur
```

All files in `Engraving/` are pure data + math. No SwiftUI, no CoreText,
no CoreGraphics drawing surface; only Foundation + the existing
`CGPoint`/`CGRect`/`CGFloat` shims `SheetMusicLayout` already uses (so
Android cross-compile works unchanged).

`SheetMusicUI` renderers and `LayoutBridge` both consume these
functions and constants. Drift is impossible because there is only one
copy.

## API design

The signatures below are the public surface of the new module. Each
function is a thin wrapper over an existing inline expression — names
chosen to read well at the call site.

### `SMuFLCodepoints.swift`

```swift
public enum SMuFLCodepoint {
    // Clefs
    public static let gClef:           UInt32 = 0xE050
    public static let gClef15mb:       UInt32 = 0xE051
    public static let gClef8vb:        UInt32 = 0xE052
    public static let gClef8va:        UInt32 = 0xE053
    public static let gClef15ma:       UInt32 = 0xE054
    public static let cClef:           UInt32 = 0xE05C
    public static let fClef:           UInt32 = 0xE062
    public static let fClef15mb:       UInt32 = 0xE063
    public static let fClef8vb:        UInt32 = 0xE064
    public static let fClef8va:        UInt32 = 0xE065
    public static let fClef15ma:       UInt32 = 0xE066
    public static let percussionClef:  UInt32 = 0xE069
    public static let percussionClef2: UInt32 = 0xE06A
    // Noteheads / rests / time-sig digits / accidentals (entries
    // currently in SheetMusicUI/Rendering/SMuFLGlyph.swift moved here)
    public static let noteheadWhole:   UInt32 = 0xE0A2
    public static let noteheadHalf:    UInt32 = 0xE0A3
    public static let noteheadBlack:   UInt32 = 0xE0A4
    public static let restWhole:       UInt32 = 0xE4E3
    public static let restHalf:        UInt32 = 0xE4E4
    public static let restQuarter:     UInt32 = 0xE4E5
    public static let restEighth:      UInt32 = 0xE4E6
    public static let timeSig0:        UInt32 = 0xE080
    public static let keyFlat:         UInt32 = 0xE260
    public static let keySharp:        UInt32 = 0xE262
    // …flag glyphs, articulation glyphs, fermata glyphs as they migrate

    /// Convenience for the 0…9 time-signature digit range.
    public static func timeSigDigit(_ d: Int) -> UInt32 {
        timeSig0 + UInt32(d)
    }
}
```

The existing `SheetMusicUI/Rendering/SMuFLGlyph.swift` becomes a thin
`Character`-typed wrapper that re-exports these values:

```swift
@available(macOS 15.0, *)
enum SMuFLGlyph {
    static let gClef: Character = scalar(SMuFLCodepoint.gClef)
    // …
    private static func scalar(_ cp: UInt32) -> Character {
        Character(UnicodeScalar(cp)!)
    }
}
```

### `ClefGlyph.swift`

```swift
public enum ClefGlyph {
    /// SMuFL codepoint + Y offset (in staff-spaces, relative to the
    /// staff middle line) for `clef`. Positive offsets move DOWN in
    /// y-down screen coordinates.
    public static func glyph(
        for clef: NotatedClef,
    ) -> (codepoint: UInt32, yOffsetSp: CGFloat) {
        switch clef {
        case .treble:        (SMuFLCodepoint.gClef,           1)
        case .treble8va:     (SMuFLCodepoint.gClef8va,        1)
        case .treble8vb:     (SMuFLCodepoint.gClef8vb,        1)
        case .treble15ma:    (SMuFLCodepoint.gClef15ma,       1)
        case .treble15mb:    (SMuFLCodepoint.gClef15mb,       1)
        case .bass:          (SMuFLCodepoint.fClef,          -1)
        case .bass8va:       (SMuFLCodepoint.fClef8va,       -1)
        case .bass8vb:       (SMuFLCodepoint.fClef8vb,       -1)
        case .soprano:       (SMuFLCodepoint.cClef,           2)
        case .alto:          (SMuFLCodepoint.cClef,           0)
        case .tenor:         (SMuFLCodepoint.cClef,          -1)
        case .baritone:      (SMuFLCodepoint.cClef,          -2)
        case .percussion:    (SMuFLCodepoint.percussionClef,  0)
        case .percussion2:   (SMuFLCodepoint.percussionClef2, 0)
        }
    }
}
```

### `KeySignatureSteps.swift`

```swift
public enum KeySignatureSteps {
    /// Treble-staff steps for each sharp in canonical engraving order
    /// (F♯ C♯ G♯ D♯ A♯ E♯ B♯). Middle line = 0, positive = up.
    public static let sharps: [Int] = [4, 1, 5, 2, -1, 3, 0]

    /// Treble-staff steps for each flat (B♭ E♭ A♭ D♭ G♭ C♭ F♭).
    public static let flats: [Int] = [0, 3, -1, 2, -2, 1, -3]

    /// Horizontal advance between consecutive accidentals.
    public static func advance(sp: CGFloat) -> CGFloat { sp * 1.4 }

    /// Convert a step value to a Y offset relative to the staff-middle
    /// reference Y (positive step = up = negative dy in y-down coords).
    public static func stepDy(step: Int, sp: CGFloat) -> CGFloat {
        -CGFloat(step) * sp / 2
    }
}
```

### `TimeSignatureLayout.swift`

```swift
public enum TimeSignatureLayout {
    public static func digitAdvance(sp: CGFloat) -> CGFloat { sp * 1.4 }

    /// `(numeratorOffsetX, denominatorOffsetX, maxWidth)` such that the
    /// two rows are centred on the same vertical axis at `origin.x`.
    public static func rowOffsets(
        numerator: Int, denominator: Int, sp: CGFloat,
    ) -> (numeratorOffsetX: CGFloat,
          denominatorOffsetX: CGFloat,
          maxWidth: CGFloat) { … }

    /// Y of the numerator row baseline anchor relative to the staff
    /// middle. (`−sp` — one staff space above.)
    public static func numeratorDy(sp: CGFloat) -> CGFloat { -sp }
    public static func denominatorDy(sp: CGFloat) -> CGFloat { sp }
}
```

### `StemGeometry.swift`

```swift
public enum StemGeometry {
    /// Horizontal distance from a Bravura `noteheadBlack` centre to the
    /// stem (1.18 sp head, 0.59 sp half-width).
    public static func attachDx(sp: CGFloat) -> CGFloat { sp * 0.59 }

    public struct Result {
        public let xStem: CGFloat
        public let startY: CGFloat
        public let endY: CGFloat
    }

    /// Compute stem geometry for a chord. `beamY` substitutes for the
    /// natural stem end when the chord is beamed (the beam Y becomes
    /// the stem terminus on the beam-side).
    public static func compute(
        noteOrigins: [CGPoint],
        direction: StemDirection,
        beamY: CGFloat?,
        defaultStemLength: CGFloat,
        sp: CGFloat,
    ) -> Result { … }
}
```

### `TieArcGeometry.swift`

```swift
public enum TieArcGeometry {
    /// Four cubic-Bezier anchors for a symmetric tie or slur arc.
    /// Renderers either pass these to `Path.curve(to:control1:control2:)`
    /// directly (SwiftUI/PDF) or tessellate them to line segments
    /// (Android — wire format has no curve opcode).
    public static func controlPoints(
        from: CGPoint, to: CGPoint,
        above: Bool, heightSp: CGFloat, sp: CGFloat,
    ) -> (p0: CGPoint, p1: CGPoint, p2: CGPoint, p3: CGPoint) { … }
}
```

## Migration

### `SheetMusicUI` renderers

Each renderer becomes a one-liner over the new API + the SwiftUI draw
call. Example for `ClefRenderer.draw`:

```swift
let clef = NotatedClef(rawType: rawType)
let (cp, yOffsetSp) = ClefGlyph.glyph(for: clef)
let glyph = Character(UnicodeScalar(cp)!)
context.drawGlyph(
    glyph,
    at: CGPoint(x: origin.x, y: origin.y + yOffsetSp * metrics.sp),
    size: metrics.glyphFontSize,
)
```

The renderer no longer owns the data; it only does the platform-
specific draw call (SwiftUI here). Apply the same pattern to
`KeySignatureRenderer`, `TimeSignatureRenderer`, `StemRenderer`.

`SMuFLGlyph.swift` continues to exist as the `Character`-typed
re-export — it stays in `SheetMusicUI` because `GraphicsContext.drawGlyph`
takes `Character`, not `UInt32`.

### `LayoutBridge`

After the engraving module lands, the bridge's `encodeElement` switch
becomes a shallow translator over the shared API. Example for the clef
case:

```swift
case let .clef(rawType, origin, _):
    let clef = NotatedClef(rawType: rawType)
    let (cp, yOffsetSp) = ClefGlyph.glyph(for: clef)
    let cx = mox + Double(origin.x)
    let cy = moy + Double(origin.y) + Double(yOffsetSp) * sp
    out.append(.glyph(
        codepoint: cp, x: cx * ptToMM, y: (cy + baselineDy) * ptToMM,
        size: glyphSize * ptToMM, fontId: .smufl,
    ))
```

The Android-specific concerns that stay in `LayoutBridge`:
- `centerToBaselineDy(...)` — converts Apple-center-anchor Y to Android
  baseline-anchor Y. Calls `FontMetrics.provider`.
- Tessellation of `TieArcGeometry.controlPoints` into a line-segment
  polyline. The wire format (`moveTo`/`lineTo`/`stroke`) has no curve
  opcode and SwiftUI/PDF do not need tessellation.

### Tests

Move the existing per-renderer unit tests where applicable, and add
new pure-data tests in `Tests/SheetMusicTests/Layout/Engraving/`:

- `ClefGlyphTests.swift` — every `NotatedClef` returns the expected
  codepoint + yOffsetSp.
- `KeySignatureStepsTests.swift` — `sharps` / `flats` have expected
  lengths and first/last values; `stepDy` returns expected dy for sample
  steps.
- `TimeSignatureLayoutTests.swift` — single-digit and multi-digit
  centering produces the expected offsets.
- `StemGeometryTests.swift` — beamed vs unbeamed cases for both
  directions.

These tests run on Apple (existing test target) and Android (Apple-only
imports excluded under `#if !os(Android)` per
`feedback_example_app_outside_swiftpm`).

## Sequencing

If implemented in one PR, do it in this order:

1. **Add `SMuFLCodepoints.swift`** (smallest, no consumer wiring needed).
   Verify Apple + Android builds.
2. **Add `ClefGlyph.swift`**. Switch `ClefRenderer` to it. Verify Apple
   `swift test` + Mac example app + Android cross-compile.
3. **Add `KeySignatureSteps.swift`**. Switch `KeySignatureRenderer`.
   Verify same.
4. **Add `TimeSignatureLayout.swift`**. Switch `TimeSignatureRenderer`.
   Verify same.
5. **Add `StemGeometry.swift`**. Switch `StemRenderer`. Verify same.
6. **Add `TieArcGeometry.swift`**. (No SheetMusicUI consumer yet —
   the existing UI uses SwiftUI Path directly. We add it for the
   Android consumer + future PDF reuse.)
7. **Migrate `LayoutBridge`** to consume all of the above. Drop the
   inline duplicates. Verify Android emulator renders identically to
   the pre-refactor screenshot.

Each step is a single commit. The Android example app does not need
new fonts or new wire-format changes — the bridge stays the same shape,
just calls into the shared module instead of inline code.

## Verification

- `swift test` green on Apple (existing tests + new Engraving tests).
- Android cross-compile via `Scripts/android-build-libs.sh` succeeds
  for both ABIs.
- `Scripts/android-test.sh aarch64` runs cleanly.
- Mac example app (`SheetMusicExampleMac`) renders identically.
- iOS example app renders identically.
- Android emulator screenshot from
  `worktree-android-compose-example` looks identical to the pre-
  refactor state.

## Non-goals

- Adding any new visible feature (no new clef variants, no new
  articulations, no slur rendering on the SwiftUI side). This refactor
  is "extract" only.
- Touching the audio / playback path.
- Changing the public surface of `LayoutElement` or `LayoutDocument`.
- Changing the `DrawProgram` wire format (no new opcodes).
- Moving Android-specific code (center-to-baseline conversion, bezier
  tessellation) into `SheetMusicLayout`. Those stay in `LayoutBridge`.

## Risk + mitigation

| Risk | Mitigation |
|---|---|
| A subtle numeric mismatch between old inline math and new function (e.g. `stepDy` sign flip) breaks Apple rendering | Snapshot the Mac example app before the refactor, diff against post-refactor render. |
| `NotatedClef` cases that don't exist today (15ma/15mb on the bass, percussion2) silently pick the wrong glyph | Cover every case in `ClefGlyphTests` — exhaustive switch + `CaseIterable` iteration in the test. |
| `SheetMusicUI`'s `SMuFLGlyph` re-export creates a circular dep | `SheetMusicUI` already depends on `SheetMusicLayout`; the new types live in Layout, UI consumes them. No cycle. |
| The current `worktree-android-compose-example` branch's inline `LayoutBridge` fixes (in flight) collide with this refactor | Land the visible-fix commits on the worktree branch first (clef/keysig/timesig/stem/text + tuplet/melisma/tie). Refactor lands afterward, rewriting `LayoutBridge` to call the new module while keeping the rendered output identical. |

## Out-of-scope follow-ups

- Move SwiftUI `Path`-based slur rendering to consume
  `TieArcGeometry.controlPoints`. (Mechanical change once the geometry
  is shared.)
- Extend `Engraving` with the remaining renderer-embedded knowledge —
  articulation glyph mapping (`ArticulationRenderer`), fermata Y
  metrics (`FermataGlyphMetrics` already lives in Layout but its
  callers don't yet), hairpin / volta / pedal spanner anchors. Each
  is a separate small extraction following the same pattern.
- A `SheetMusicLayoutAndroid` rendering target that owns the
  Android-specific bits (`centerToBaselineDy`, tessellation) so they
  stop being inside the example app's JNI target. This is a longer-term
  cleanup with implications for distribution.
