# Font metrics DI — `SheetMusicLayout` 平板化 (Android port Phase 2)

**Status:** draft (2026-05-19)
**Worktree:** `.claude/worktrees/font-metrics-di` (branch `feature/font-metrics-di`, off `feature/android-toolchain` HEAD `855ffd4`)
**Roadmap:** Phase 2 of 4 — see memory `project_android_port_roadmap`

## Goal

Make `SheetMusicLayout` compile against the Foundation-only Swift Android SDK
so that `Score → LayoutDocument` runs on Android. Achieve this by introducing
a `FontMetricsProvider` DI seam — Layout consumes glyph and text measurements
through a protocol instead of calling CoreText directly. A new
`SheetMusicLayoutApple` target supplies the CoreText-backed implementation;
non-Apple builds fall back to a `StubFontMetricsProvider` that returns
rectangle approximations (good enough for `LayoutDocument` generation,
to be replaced by a real Skia/Android-font provider in Phase 4).

Non-goals:

- No CoreGraphics geometry abstraction. `CGFloat / CGRect / CGPoint / CGSize /
  CGAffineTransform` are assumed available on Android via Foundation
  (swift-corelibs-foundation re-exports). Any failures discovered during
  Android cross-compile are addressed surgically (`#if canImport(CoreGraphics)`
  or a targeted import swap), not by introducing parallel struct types.
- No Android FontMetrics implementation. Phase 4 (Compose Example app)
  brings the real `SheetMusicLayoutAndroid` provider; Phase 2 only ships
  the Stub.
- No `SheetMusicAudio` changes (that is Phase 3).
- No backwards-compatibility shims. The repo has very few external
  consumers; breaking `import` paths and `@available` annotations is
  acceptable.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ SheetMusicLayout (Foundation-only, Android-compilable)         │
│                                                                 │
│   - FontMetricsProvider protocol + LayoutFont/FontWeight/InkBounds│
│   - enum FontMetrics { static var provider = Stub… }            │
│   - StubFontMetricsProvider (rectangle approximations)          │
│   - SMuFLFamily.bravura = "Bravura" (replaces BravuraFont.familyName│
│     internally; the typed Apple BravuraFont still exists in Apple)│
│   - BraceMetrics / FermataGlyphMetrics / HarmonyRendering /     │
│     LayoutEngine+Lyrics 全部 FontMetrics.provider 経由に書き換え │
└─────────────────────────────────────────────────────────────────┘
              ▲                                  ▲
              │ FontMetrics.provider = …          │ FontMetrics.provider = …
              │                                  │
┌─────────────┴───────────────────┐  ┌───────────┴────────────────────┐
│ SheetMusicLayoutApple (NEW)     │  │ (Future Phase 4:                │
│ Apple-only @ macOS 15+/iOS …    │  │  SheetMusicLayoutAndroid        │
│                                 │  │  with Skia / Android FontMetrics)│
│   - AppleFontMetricsProvider    │  └────────────────────────────────┘
│     (CoreText impl, internal    │
│      NSLock + unified cache)    │
│   - SheetMusicLayoutApple.install
│     (static-let-idempotent)     │
│   - SheetMusicFonts.register    │
│     (urls:) ← moved             │
│   - BravuraFont ← moved         │
│   - Resources/Bravura.otf       │
└─────────────────────────────────┘
              ▲
              │ implicit auto-install via _ = SheetMusicLayoutApple.install
              │
┌─────────────┴────────────┐  ┌───────────────────────┐
│ SheetMusicUI            │  │ SheetMusicPDF         │
│ + depends LayoutApple   │  │ + depends LayoutApple │
│ ScoreView.init で叩く    │  │ PDF entry で叩く       │
└─────────────────────────┘  └───────────────────────┘
```

**Why this shape:**

- **DI seam at module boundary, not at call sites.** Layout's internal call
  sites already number in the tens (`BraceMetrics`, `FermataGlyphMetrics`,
  `HarmonyRendering`, `LayoutEngine+Lyrics`, `LayoutEngine+Placement` etc).
  Threading a `provider:` parameter through every call would balloon public
  API surface (`LayoutEngine(score:, fontMetrics:)`) and force consumer
  rewrites (UI / PDF / Example). A single global `FontMetrics.provider`,
  installed once at app launch, keeps Layout's internal API unchanged.
- **Mirrors existing `BravuraFont.register` pattern.** The codebase
  already uses static-let-idempotent registration with side effects
  (`BravuraFont.register: Bool = { … CTFontManagerRegisterFontsForURL …; return ok }()`).
  `SheetMusicLayoutApple.install` follows the same shape — discoverable,
  no module-load magic, no per-call parameter passing.
- **Auto-install via UI/PDF dependency.** Host apps consuming
  `SheetMusicUI` or `SheetMusicPDF` get `SheetMusicLayoutApple.install`
  triggered transparently in `ScoreView.init` (and the PDF render entry).
  Only headless Layout consumers (`RenderPreviews`, isolated Layout
  tests) need to call `_ = SheetMusicLayoutApple.install` explicitly.
- **DEBUG guard against silent fallback.** When `LayoutEngine.init` sees
  `FontMetrics.provider is StubFontMetricsProvider` on a platform where
  `canImport(CoreText)` is true, it `assertionFailure`s in DEBUG and logs
  in Release. Forgotten install becomes loud, not a silent rendering
  regression.

## Public API

### New in `SheetMusicLayout`

```swift
// Sources/SheetMusicLayout/Fonts/FontMetricsProvider.swift

public struct LayoutFont: Hashable, Sendable {
    public let face: String          // "Bravura", "Edwin", or "" = system
    public let pointSize: CGFloat
    public let weight: FontWeight
    public init(face: String, pointSize: CGFloat, weight: FontWeight = .regular)
}

public enum FontWeight: Sendable, Hashable {
    case regular
    case semibold                    // only used by lyrics
}

public struct InkBounds: Sendable {
    public let leftBearing: CGFloat
    public let width: CGFloat
}

public protocol FontMetricsProvider: Sendable {
    func ascent(font: LayoutFont) -> CGFloat
    func descent(font: LayoutFont) -> CGFloat
    func glyphPathBoundingBox(font: LayoutFont, codepoint: UInt16) -> CGRect?
    func typographicWidth(text: String, font: LayoutFont) -> CGFloat
    func inkBounds(text: String, font: LayoutFont) -> InkBounds
}

public enum FontMetrics {
    // nonisolated(unsafe) for the same reason existing BraceMetrics.bboxCache
    // is: install is app-launch-time-once, all subsequent access is read-only.
    public nonisolated(unsafe) static var provider: any FontMetricsProvider
        = StubFontMetricsProvider()
}

public struct StubFontMetricsProvider: FontMetricsProvider, Sendable {
    public init() {}
    public func ascent(font: LayoutFont) -> CGFloat { font.pointSize * 0.85 }
    public func descent(font: LayoutFont) -> CGFloat { font.pointSize * 0.25 }
    public func glyphPathBoundingBox(
        font: LayoutFont, codepoint: UInt16,
    ) -> CGRect? {
        CGRect(x: 0, y: 0, width: font.pointSize, height: font.pointSize * 0.7)
    }
    public func typographicWidth(text: String, font: LayoutFont) -> CGFloat {
        CGFloat(text.count) * font.pointSize * 0.5
    }
    public func inkBounds(text: String, font: LayoutFont) -> InkBounds {
        InkBounds(leftBearing: 0,
                  width: typographicWidth(text: text, font: font))
    }
}
```

```swift
// Sources/SheetMusicLayout/Fonts/SMuFLFamily.swift

public enum SMuFLFamily {
    public static let bravura = "Bravura"
}
```

### New in `SheetMusicLayoutApple`

```swift
// Sources/SheetMusicLayoutApple/AppleFontMetricsProvider.swift

@available(macOS 15.0, *)
public struct AppleFontMetricsProvider: FontMetricsProvider {
    public init() {}
    // CoreText impl — port the bodies of:
    //   BraceMetrics.measureNaturalBBoxWidth      → glyphPathBoundingBox
    //   FermataGlyphMetrics.measure (ascent/descent/path) → ascent/descent/glyphPathBoundingBox
    //   LayoutEngine+Lyrics.lyricsTextWidth        → typographicWidth(weight: .semibold)
    //   HarmonyRendering.inkBounds / ctLine        → inkBounds / typographicWidth
    // Internal state:
    //   private let lock = NSLock()
    //   private nonisolated(unsafe) var ctFontCache: [LayoutFont: CTFont] = [:]
    // All public methods acquire `lock` for the duration. Mirrors HarmonyRendering's
    // existing ctLock rationale (CTFont creation for unregistered family names
    // deadlocks under parallel access; one mutex around the whole pipeline).
}
```

```swift
// Sources/SheetMusicLayoutApple/SheetMusicLayoutApple.swift

@available(macOS 15.0, *)
public enum SheetMusicLayoutApple {
    /// Static-let-idempotent install. First reference triggers the side
    /// effect (set FontMetrics.provider to AppleFontMetricsProvider). All
    /// subsequent references are free. Safe to call from multiple sites
    /// (ScoreView.init, PDF entry, RenderPreviews, tests).
    public static let install: Bool = {
        FontMetrics.provider = AppleFontMetricsProvider()
        return true
    }()
}
```

### Moved from `SheetMusicLayout` to `SheetMusicLayoutApple`

- `BravuraFont` (entire file)
- `SheetMusicFonts.register(urls:)` (entire file)
- `Resources/Bravura.otf` resource

Consumers must add `import SheetMusicLayoutApple` to reference these. The
`BravuraFont.familyName` constant is duplicated as `SMuFLFamily.bravura` in
Layout for internal use; external consumers can continue to use
`BravuraFont.familyName` after adding the import.

### Removed availability annotations

`SheetMusicLayout` is Foundation-only; the existing
`@available(macOS 15.0, *)` on its public APIs goes away. The Layout
target gains no Apple-platform availability requirement.

`SheetMusicLayoutApple` keeps `@available(macOS 15.0, *)` (and iOS/tvOS
equivalents) where present in the moved sources.

## Module layout & Package.swift

```
SheetMusic
  ├─→ SheetMusicCore
  ├─→ SheetMusicMSCX
  ├─→ SheetMusicMusicXML
  └─→ SheetMusicMIDI

SheetMusicLayout            (Foundation-only — NEW Android-compilable)
SheetMusicLayoutApple       (Apple-only, NEW)  ← SheetMusicLayout
SheetMusicUI                (Apple-only)       ← SheetMusicLayout, SheetMusicLayoutApple
SheetMusicAudio             (Apple-only)       ← SheetMusicCore, SheetMusicMIDI
SheetMusicPDF               (Apple-only)       ← SheetMusicLayout, SheetMusicLayoutApple, SheetMusicUI
RenderPreviews              (executable)       ← SheetMusicUI + explicit install call
```

Package.swift diff outline (`isAndroid` branch already exists from Phase 1):

```swift
// Promoted to unconditional products
.library(name: "SheetMusicLayout", targets: ["SheetMusicLayout"]),

// Unchanged targets
.target(name: "SheetMusicLayout", dependencies: ["SheetMusicCore"])
   // resources removed — Bravura.otf moves to LayoutApple

// New Apple-only product+target
if !isAndroid {
    products += [.library(name: "SheetMusicLayoutApple",
                          targets: ["SheetMusicLayoutApple"])]
    targets += [
        .target(name: "SheetMusicLayoutApple",
                dependencies: ["SheetMusicCore", "SheetMusicLayout"],
                resources: [.process("Fonts/Resources")]),
        .target(name: "SheetMusicUI",
                dependencies: ["SheetMusicCore",
                               "SheetMusicLayout",
                               "SheetMusicLayoutApple"]),
        .target(name: "SheetMusicPDF",
                dependencies: ["SheetMusicCore",
                               "SheetMusicLayout",
                               "SheetMusicLayoutApple",
                               "SheetMusicUI"]),
        // SheetMusicAudio unchanged
    ]
}

// SheetMusicTests Android dep gains "SheetMusicLayout"
```

### Bravura.otf bundle resolution

`BravuraFont.find(in:)` currently scans nested bundle name
`swift-sheet-music_SheetMusicUI.bundle`. After resource relocation, the
nested bundle name becomes `swift-sheet-music_SheetMusicLayoutApple.bundle`.
Update the string literal accordingly. `Bundle.module` resolution within
the new target works automatically.

## File-level migration map

```
Sources/SheetMusicLayout/Fonts/
    BravuraFont.swift              → moved to SheetMusicLayoutApple/
    SheetMusicFonts.swift          → moved to SheetMusicLayoutApple/
    BraceMetrics.swift             rewrite body to use FontMetrics.provider
    FermataGlyphMetrics.swift      rewrite body to use FontMetrics.provider
    Resources/Bravura.otf          → moved to SheetMusicLayoutApple/Fonts/Resources/

Sources/SheetMusicLayout/Fonts/    NEW
    FontMetricsProvider.swift      NEW
    SMuFLFamily.swift              NEW

Sources/SheetMusicLayout/Layout/
    HarmonyRendering.swift         rewrite: remove ctLock + fontCache,
                                   call FontMetrics.provider instead
    LayoutEngine+Lyrics.swift      rewrite lyricsTextWidth via provider
    LayoutEngine+Placement.swift   audit CT import, route through provider
    (all other Layout/*.swift)     drop `import CoreText`,
                                   keep `import CoreGraphics` unless
                                   Android compile rejects it

Sources/SheetMusicLayoutApple/     NEW target
    AppleFontMetricsProvider.swift NEW
    SheetMusicLayoutApple.swift    NEW (install static let)
    BravuraFont.swift              moved
    SheetMusicFonts.swift          moved
    Fonts/Resources/Bravura.otf    moved
```

## Implementation plan

Each step must keep the working tree's `swift build && swift test` green
before moving on. Step 2 has a transient Apple-quality regression
(Stub provider in use everywhere) that Step 3 cleans up.

### Step 1 — Additive scaffolding (no behaviour change)

1. Add `SheetMusicLayout/Fonts/FontMetricsProvider.swift` (protocol +
   `LayoutFont` + `FontWeight` + `InkBounds` + `FontMetrics` enum +
   `StubFontMetricsProvider`).
2. Add `SheetMusicLayout/Fonts/SMuFLFamily.swift`.
3. Update `Package.swift` to declare `SheetMusicLayoutApple` target +
   product (still empty).
4. Add `SheetMusicLayoutApple/AppleFontMetricsProvider.swift`
   (CoreText impl, fully functional but unreferenced).
5. Add `SheetMusicLayoutApple/SheetMusicLayoutApple.swift`
   (`install` static let, not yet called from anywhere).
6. Verify `swift build && swift test` green.

### Step 2 — Internal Layout rewrite (provider-routed)

7. `BraceMetrics.swift`: replace `measureNaturalBBoxWidth` CT body with
   `FontMetrics.provider.glyphPathBoundingBox(font:codepoint:)`.
   Remove `bboxLock`/`bboxCache` (provider owns caching now).
8. `FermataGlyphMetrics.swift`: replace `measure` CT body with
   provider `ascent`/`descent`/`glyphPathBoundingBox` calls. Remove
   `cache`/`lock`.
9. `LayoutEngine+Lyrics.swift`: replace `lyricsTextWidth` with
   `FontMetrics.provider.typographicWidth(text:font:)`
   using `LayoutFont(face: "", pointSize: sp*2.2, weight: .semibold)`.
   The `""` face means "system" — provider decides how to resolve.
10. `HarmonyRendering.swift`: replace CT path with provider calls.
    Remove `ctLock` and `fontCache` (provider owns both now).
11. `LayoutEngine+Placement.swift`: audit `import CoreText`, route any
    direct CT use through the provider.
12. After each file rewrite: `swift test` green. Apple Layout output
    visibly degrades to Stub quality during Step 2 — expected, fixed
    in Step 3.

### Step 3 — Apple install hookup

13. Physically move `Sources/SheetMusicLayout/Fonts/BravuraFont.swift`
    to `Sources/SheetMusicLayoutApple/BravuraFont.swift`.
14. Move `Sources/SheetMusicLayout/Fonts/SheetMusicFonts.swift` to
    `Sources/SheetMusicLayoutApple/SheetMusicFonts.swift`.
15. Move `Bravura.otf` resource to
    `Sources/SheetMusicLayoutApple/Fonts/Resources/`. Update
    `BravuraFont.find(in:)` `nestedURL` lookup string to
    `"swift-sheet-music_SheetMusicLayoutApple"`.
16. Add `SheetMusicLayoutApple` to `SheetMusicUI` deps. Add
    `_ = SheetMusicLayoutApple.install` at the top of
    `ScoreView.init` (next to the existing
    `_ = BravuraFont.register`).
17. Add `SheetMusicLayoutApple` to `SheetMusicPDF` deps. Add
    `_ = SheetMusicLayoutApple.install` at the PDF render entry point.
18. Add a DEBUG guard inside `LayoutEngine.init`:
    ```swift
    #if DEBUG && canImport(CoreText)
    assert(!(FontMetrics.provider is StubFontMetricsProvider),
           "SheetMusicLayoutApple.install を呼んでください "
           + "(or set FontMetrics.provider explicitly)")
    #endif
    ```
19. `RenderPreviews`: add `import SheetMusicLayoutApple` +
    `_ = SheetMusicLayoutApple.install` early in entry point.
20. Verify `swift build && swift test` green — Apple metrics now back
    to original quality.
21. Verify Example app build:
    - macOS: `xcodebuild -project Example/SheetMusicExample.xcodeproj
      -scheme SheetMusicExampleMac build`
    - iOS: `xcodebuild -project Example/SheetMusicExample.xcodeproj
      -scheme SheetMusicExample -destination
      'platform=iOS Simulator,name=iPhone 17' build`
    - Regenerate xcodeproj first if any `Example/project.yml` changes
      were necessary: `cd Example && xcodegen generate`.

### Step 4 — Enable Layout on Android

22. In `Package.swift`, hoist `SheetMusicLayout` product into the
    unconditional `products` array. Add `"SheetMusicLayout"` to the
    `isAndroid ? […]` branch of `SheetMusicTests` deps.
23. Sweep remaining `import CoreText` in `Sources/SheetMusicLayout/`
    and delete (or gate via `#if canImport(CoreText)` if a fallback
    matters).
24. Sweep `import CoreGraphics` similarly — keep as-is if Android
    Foundation provides `CGRect` etc, otherwise gate with
    `#if canImport(CoreGraphics)`. Driven by actual cross-compile
    errors, not preemptive rewriting.
25. `os.Logger` use inside `SheetMusicLayout` (if any survives): gate
    with `#if canImport(os)` and provide a `print`-based fallback or
    no-op for non-Apple.
26. Run `Scripts/android-test.sh`. Record post-Phase 2 test count
    (previously 679 tests / 116 suites on Android).
27. Add a minimal Android-friendly smoke test
    (`Tests/SheetMusicTests/Layout/LayoutEngineAndroidSmokeTests.swift`):
    parse `midi01.mscx` → `LayoutEngine().layout(score:)` with Stub
    provider → assert `LayoutDocument.systems` non-empty.

### Step 5 — Cleanup

28. Strip `@available(macOS 15.0, *)` (and equivalents) from
    `SheetMusicLayout` public APIs.
29. Update `CLAUDE.md`:
    - "Library layout" section gains `SheetMusicLayoutApple`.
    - "Format support matrix" / Android section gains Layout under
      Android-supported.
30. Update `docs/musescore-engraving-reference.md` if any cross-refs
    became stale (likely none, but check the font/metrics section).
31. Update memory `project_android_port_roadmap.md`: mark Phase 2
    completed, note new Android test count.

## Testing

### Apple regression coverage

- Full `swift test` green (Layout / UI / PDF / Audio / Core / MIDI
  / MSCX / MusicXML suites).
- `MidiExportTests` 12 / 12 still green.
- Mac + iOS Example app `xcodebuild` green.
- Visual smoke (Mac Example, manual): Scarlatti K1 (chord symbols),
  a multi-voice piece (beaming + ties), a piece with lyrics + melisma
  (lyrics width measurement), a piece with brace + 3+ staves
  (`BraceMetrics`).

### New unit tests

- `StubFontMetricsProvider` — each method returns expected
  rectangle-approximation values (deterministic, drives `Score →
  LayoutDocument` on Android without runtime FontMetrics).
- `AppleFontMetricsProvider` — Bravura known SMuFL codepoints
  (e.g. `0xE4C0` fermata, `0xE000` brace) return bounding boxes in
  expected ranges. Edwin / system-semibold text of a known string
  returns width in expected range.
- `SheetMusicLayoutApple.install` — first reference flips
  `FontMetrics.provider` to `AppleFontMetricsProvider`; second
  reference is no-op.
- DEBUG guard — `LayoutEngine.init` with Stub provider on Apple
  fires the assertion (use Swift Testing's
  `withKnownIssue` / explicit precondition test pattern).

### Android acceptance

- `Scripts/android-test.sh` green.
- New `LayoutEngineAndroidSmokeTests` proves Phase 2's roadmap
  acceptance ("`LayoutEngine` が `LayoutDocument` を生成できる").
- Android test count grows from Phase 1 baseline (679 / 116) by the
  Layout suite contribution — record actual delta in Step 4 / 31.

## Risk & mitigation

- **Forgotten install (Stub used on Apple unintentionally).** Mitigated
  by (a) `SheetMusicUI` and `SheetMusicPDF` auto-installing in their
  entry points so any host using them gets install transitively, and
  (b) DEBUG-only `assertionFailure` in `LayoutEngine.init` when Stub
  is detected on a CoreText-capable platform.
- **Bundle nested-name regression for Bravura.otf.** `BravuraFont`
  currently looks up the SheetMusicUI nested bundle by string literal.
  After moving the resource, that string must change to
  `SheetMusicLayoutApple`. Caught by the Mac Example app smoke test
  (tofu boxes if missed).
- **Provider cache races under Swift Testing parallelism.** Apple
  provider holds an `NSLock` around all CT work for the same reason
  `HarmonyRendering.ctLock` exists today (CTFont creation for
  unregistered family names deadlocks under concurrent access). The
  central provider lock supersedes the per-file locks being removed
  in Step 2.
- **Step 2 transient regression visibility.** Between Step 2 and
  Step 3, Apple builds run with Stub metrics — visually broken. Don't
  commit Step 2 in isolation without Step 3 immediately following.
  Implementation plan should treat Step 2 + Step 3 as a single
  reviewable unit (or land Step 2 on a separate branch and merge
  together).
- **CoreGraphics availability on Android.** Section "Non-goals"
  punts CG abstraction. If a Foundation re-export turns out to be
  missing for some CG type used in Layout, fall back to `#if
  canImport(CoreGraphics)` per import site. Don't expand scope into
  full geometry abstraction.
- **Conflict with Phase 1.6 (SheetMusicZip) on `Package.swift` and
  `CLAUDE.md`.** Phase 1.6 lands on main first (planned). Before
  merging Phase 2, rebase onto current main and reconcile the
  `isAndroid ? […]` dependency arrays in `Package.swift` and the
  Android-format-support matrix in `CLAUDE.md`. No source-file
  overlap with Phase 1.6 (Layout vs Zip are disjoint).

## Definition of done

1. `swift build` (host Apple) green.
2. `swift test` (host Apple) green; new unit tests for
   `Stub` / `Apple` providers + install + DEBUG guard included.
3. `SWIFT_SHEET_MUSIC_ANDROID=1` cross-build of `SheetMusicLayout`
   green.
4. `Scripts/android-test.sh` green; Layout suite contributes to the
   Android test count (record delta).
5. Mac + iOS Example app `xcodebuild` green.
6. Mac Example app manual visual smoke: chord symbols, multi-voice,
   lyrics with melisma, multi-staff brace — no regressions.
7. `swiftlint --quiet Sources Tests` — 0 warnings/errors.
8. `CLAUDE.md` (Library layout + Android matrix) and memory
   `project_android_port_roadmap.md` (Phase 2 → completed + test
   counts) updated.

## Related memory / docs

- `project_android_port_roadmap` — overall 4-phase plan
- `project_incremental_layout_roadmap` — Layout 改修方針、Phase 2 と
  整合
- `feedback_worktree_layout` — worktree 配置・ベース選択
- `feedback_session_recommended_default` — 設計選択肢の提示方針
- `feedback_big_task_autonomy` — multi-phase 実装の自動化範囲
- `docs/superpowers/specs/2026-05-18-android-toolchain-design.md` —
  Phase 1 toolchain spec、`isAndroid` 分岐の前提
