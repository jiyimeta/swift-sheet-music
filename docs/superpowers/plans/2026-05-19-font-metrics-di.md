# Font metrics DI — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `SheetMusicLayout` compile against the Foundation-only Swift Android SDK by introducing a `FontMetricsProvider` DI seam; ship a new `SheetMusicLayoutApple` target with the CoreText-backed implementation.

**Architecture:** `SheetMusicLayout` exposes a `FontMetricsProvider` protocol and a global `FontMetrics.provider` initially set to a `StubFontMetricsProvider` (rectangle approximations). A new `SheetMusicLayoutApple` target provides `AppleFontMetricsProvider` (CoreText) and `SheetMusicLayoutApple.install` (static-let-idempotent). `SheetMusicUI` and `SheetMusicPDF` depend on `LayoutApple` and trigger `install` in their entry points so Apple consumers get auto-installation; Android consumers fall back to the Stub.

**Tech Stack:** Swift 6.2, SwiftPM, Swift Testing (`@Test`/`#expect`), CoreText (Apple side), Foundation only (Layout side). Worktree: `.claude/worktrees/font-metrics-di`, branch `feature/font-metrics-di`, off `feature/android-toolchain` HEAD `855ffd4`.

**Spec:** `docs/superpowers/specs/2026-05-19-font-metrics-di-design.md`.

**Discipline:**
- TDD where new code is introduced (Tasks 1, 4, 5, 22).
- Refactor tasks (Tasks 6–11) are guarded by the existing test suite — run `swift test` after each one.
- **Do NOT push to `main` between Task 11 and Task 17.** During that window, Apple builds run with `StubFontMetricsProvider` and render visibly degraded. Task 17 restores correct metrics. Commits on the feature branch are fine.
- Use `swift test` (host Apple) green as the per-task gate unless otherwise stated.
- `swift build` (host Apple) implied by `swift test`.

---

## File Structure

**New (`SheetMusicLayout`):**
- `Sources/SheetMusicLayout/Fonts/FontMetricsProvider.swift` — protocol + `LayoutFont` + `FontWeight` + `InkBounds` + `FontMetrics` enum + `StubFontMetricsProvider`
- `Sources/SheetMusicLayout/Fonts/SMuFLFamily.swift` — `"Bravura"` constant for in-Layout use

**New (`SheetMusicLayoutApple` target):**
- `Sources/SheetMusicLayoutApple/AppleFontMetricsProvider.swift`
- `Sources/SheetMusicLayoutApple/SheetMusicLayoutApple.swift` (`install` entry)

**Moved (Layout → LayoutApple):**
- `Sources/SheetMusicLayout/Fonts/BravuraFont.swift` → `Sources/SheetMusicLayoutApple/BravuraFont.swift`
- `Sources/SheetMusicLayout/Fonts/SheetMusicFonts.swift` → `Sources/SheetMusicLayoutApple/SheetMusicFonts.swift`
- `Sources/SheetMusicLayout/Fonts/Resources/Bravura.otf` → `Sources/SheetMusicLayoutApple/Fonts/Resources/Bravura.otf`

**Modified (Layout):**
- `Sources/SheetMusicLayout/Fonts/BraceMetrics.swift` — rewrite to use provider
- `Sources/SheetMusicLayout/Fonts/FermataGlyphMetrics.swift` — rewrite to use provider
- `Sources/SheetMusicLayout/Layout/HarmonyRendering.swift` — rewrite, drop `ctLock` + `fontCache`
- `Sources/SheetMusicLayout/Layout/LayoutEngine+Lyrics.swift` — rewrite `lyricsTextWidth`
- `Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift` — drop unused `import CoreText`
- `Sources/SheetMusicLayout/Layout/LayoutEngine.swift` — DEBUG guard at top of `layout(...)`

**Modified (other Apple targets):**
- `Sources/SheetMusicUI/ScoreView.swift` — `import SheetMusicLayoutApple`, swap `BravuraFont.register` → `SheetMusicLayoutApple.install`
- `Sources/SheetMusicPDF/PDFExporter.swift` — same swap
- `Sources/RenderPreviews/main.swift` — same swap

**Modified (configuration / docs):**
- `Package.swift`
- `CLAUDE.md`
- (memory) `~/.claude/projects/.../memory/project_android_port_roadmap.md`

**New tests:**
- `Tests/SheetMusicTests/Layout/StubFontMetricsProviderTests.swift`
- `Tests/SheetMusicTests/Layout/AppleFontMetricsProviderTests.swift`
- `Tests/SheetMusicTests/Layout/SheetMusicLayoutAppleInstallTests.swift`
- `Tests/SheetMusicTests/Layout/LayoutEngineAndroidSmokeTests.swift`

---

## Task 1: Add `FontMetricsProvider` + `StubFontMetricsProvider` (TDD)

**Files:**
- Create: `Sources/SheetMusicLayout/Fonts/FontMetricsProvider.swift`
- Test: `Tests/SheetMusicTests/Layout/StubFontMetricsProviderTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/Layout/StubFontMetricsProviderTests.swift`:

```swift
import Foundation
import Testing
@testable import SheetMusicLayout

@Suite("StubFontMetricsProvider")
struct StubFontMetricsProviderTests {
    private let stub = StubFontMetricsProvider()

    @Test func ascentScalesWithPointSize() {
        let f = LayoutFont(face: "Bravura", pointSize: 4)
        #expect(stub.ascent(font: f) == 4 * 0.85)
    }

    @Test func descentScalesWithPointSize() {
        let f = LayoutFont(face: "Bravura", pointSize: 4)
        #expect(stub.descent(font: f) == 4 * 0.25)
    }

    @Test func glyphPathBoundingBoxReturnsRectangle() {
        let f = LayoutFont(face: "Bravura", pointSize: 4)
        let bbox = stub.glyphPathBoundingBox(font: f, codepoint: 0xE000)
        #expect(bbox == CGRect(x: 0, y: 0, width: 4, height: 4 * 0.7))
    }

    @Test func typographicWidthScalesWithCharCount() {
        let f = LayoutFont(face: "", pointSize: 10, weight: .semibold)
        #expect(stub.typographicWidth(text: "abc", font: f) == 3 * 10 * 0.5)
    }

    @Test func inkBoundsMatchTypographicWidth() {
        let f = LayoutFont(face: "Edwin", pointSize: 12)
        let ink = stub.inkBounds(text: "C", font: f)
        #expect(ink.leftBearing == 0)
        #expect(ink.width == 1 * 12 * 0.5)
    }

    @Test func defaultProviderIsStub() {
        // No install called → default should be Stub. Sanity check.
        #expect(FontMetrics.provider is StubFontMetricsProvider)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```
swift test --filter StubFontMetricsProviderTests
```

Expected: FAIL — `StubFontMetricsProvider` / `LayoutFont` / `FontMetrics` not found.

- [ ] **Step 3: Implement the provider**

Create `Sources/SheetMusicLayout/Fonts/FontMetricsProvider.swift`:

```swift
import CoreGraphics
import Foundation

/// Font descriptor used by `FontMetricsProvider`. Identifies the face
/// (e.g. "Bravura", "Edwin", "" for system), the rendering point size,
/// and the weight when the face has multiple weights (lyrics use
/// semibold; SMuFL glyph fonts ignore weight).
public struct LayoutFont: Hashable, Sendable {
    public let face: String
    public let pointSize: CGFloat
    public let weight: FontWeight

    public init(
        face: String,
        pointSize: CGFloat,
        weight: FontWeight = .regular,
    ) {
        self.face = face
        self.pointSize = pointSize
        self.weight = weight
    }
}

public enum FontWeight: Sendable, Hashable {
    case regular
    case semibold
}

/// Ink-pixel extents of a typeset string. `leftBearing` is the offset
/// from the typographic origin to the leftmost inked pixel; `width`
/// is the horizontal extent of the inked region.
public struct InkBounds: Sendable {
    public let leftBearing: CGFloat
    public let width: CGFloat

    public init(leftBearing: CGFloat, width: CGFloat) {
        self.leftBearing = leftBearing
        self.width = width
    }
}

/// Platform-agnostic interface to font measurement. `SheetMusicLayout`
/// holds the protocol; concrete implementations live in
/// `SheetMusicLayoutApple` (CoreText) and a future
/// `SheetMusicLayoutAndroid`. A `StubFontMetricsProvider` provides
/// rectangle approximations so `LayoutEngine` can produce a
/// `LayoutDocument` on platforms with no real provider yet.
public protocol FontMetricsProvider: Sendable {
    func ascent(font: LayoutFont) -> CGFloat
    func descent(font: LayoutFont) -> CGFloat
    func glyphPathBoundingBox(
        font: LayoutFont, codepoint: UInt16,
    ) -> CGRect?
    func typographicWidth(
        text: String, font: LayoutFont,
    ) -> CGFloat
    func inkBounds(text: String, font: LayoutFont) -> InkBounds
}

/// Global injection point. Apple hosts trigger
/// `SheetMusicLayoutApple.install` (transitively via `SheetMusicUI` or
/// `SheetMusicPDF`); non-Apple hosts leave the Stub in place or assign
/// their own provider.
public enum FontMetrics {
    // App-launch-time-once mutation; reader path is read-only. Same
    // unchecked-Sendable rationale as the existing `bboxCache`/`fontCache`
    // statics elsewhere in this target.
    public nonisolated(unsafe) static var provider: any FontMetricsProvider
        = StubFontMetricsProvider()
}

/// Rectangle approximations sized off the requested `pointSize`.
/// Numbers chosen to match Bravura's typical SMuFL proportions
/// (1 em = 4 sp; ascent ≈ 0.85 em; descent ≈ 0.25 em; glyph bbox
/// ≈ 1 em × 0.7 em). Good enough for `LayoutDocument` generation;
/// not pixel-accurate.
public struct StubFontMetricsProvider: FontMetricsProvider {
    public init() {}

    public func ascent(font: LayoutFont) -> CGFloat {
        font.pointSize * 0.85
    }

    public func descent(font: LayoutFont) -> CGFloat {
        font.pointSize * 0.25
    }

    public func glyphPathBoundingBox(
        font: LayoutFont, codepoint _: UInt16,
    ) -> CGRect? {
        CGRect(
            x: 0, y: 0,
            width: font.pointSize,
            height: font.pointSize * 0.7,
        )
    }

    public func typographicWidth(
        text: String, font: LayoutFont,
    ) -> CGFloat {
        CGFloat(text.count) * font.pointSize * 0.5
    }

    public func inkBounds(text: String, font: LayoutFont) -> InkBounds {
        InkBounds(
            leftBearing: 0,
            width: typographicWidth(text: text, font: font),
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

```
swift test --filter StubFontMetricsProviderTests
```

Expected: PASS (6 tests).

- [ ] **Step 5: Run the full suite to verify no regressions**

```
swift test
```

Expected: PASS (everything still green; new file is additive).

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicLayout/Fonts/FontMetricsProvider.swift \
        Tests/SheetMusicTests/Layout/StubFontMetricsProviderTests.swift
git commit -m "feat(layout): add FontMetricsProvider + StubFontMetricsProvider"
```

---

## Task 2: Add `SMuFLFamily` constant

**Files:**
- Create: `Sources/SheetMusicLayout/Fonts/SMuFLFamily.swift`

- [ ] **Step 1: Create the constant**

Create `Sources/SheetMusicLayout/Fonts/SMuFLFamily.swift`:

```swift
/// SMuFL family name constants. Lives in the Foundation-only Layout
/// target so internal code (BraceMetrics, FermataGlyphMetrics,
/// HarmonyRendering) can reference "Bravura" without importing
/// `SheetMusicLayoutApple`. The Apple-side `BravuraFont.familyName`
/// is kept for external consumers and resolves to the same string.
public enum SMuFLFamily {
    public static let bravura = "Bravura"
}
```

- [ ] **Step 2: Verify build**

```
swift build
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Sources/SheetMusicLayout/Fonts/SMuFLFamily.swift
git commit -m "feat(layout): add SMuFLFamily.bravura constant for in-target use"
```

---

## Task 3: Add empty `SheetMusicLayoutApple` target in `Package.swift`

**Files:**
- Modify: `Package.swift`
- Create: `Sources/SheetMusicLayoutApple/.gitkeep` (placeholder so the empty dir survives — replaced by real sources in Tasks 4–5)

- [ ] **Step 1: Add the target and product (Apple-only branch)**

Locate the `if !isAndroid` block in `Package.swift`. Add `SheetMusicLayoutApple` as a product and target. Do not yet wire `SheetMusicUI` / `SheetMusicPDF` to depend on it (Tasks 14–15 do that).

Add to the `if !isAndroid` products list:

```swift
products += [
    .library(name: "SheetMusicLayoutApple", targets: ["SheetMusicLayoutApple"]),
    .library(name: "SheetMusicLayout", targets: ["SheetMusicLayout"]),  // moved out of if-block in Task 18; ignore here
    .library(name: "SheetMusicUI", targets: ["SheetMusicUI"]),
    .library(name: "SheetMusicAudio", targets: ["SheetMusicAudio"]),
    .library(name: "SheetMusicPDF", targets: ["SheetMusicPDF"]),
    .executable(name: "render-previews", targets: ["RenderPreviews"]),
]
```

(Leave `SheetMusicLayout` product where it currently is — Task 18 hoists it. Just add the new line for `SheetMusicLayoutApple`.)

Add to the `if !isAndroid` targets list (alphabetised next to `SheetMusicUI`):

```swift
.target(
    name: "SheetMusicLayoutApple",
    dependencies: ["SheetMusicCore", "SheetMusicLayout"],
),
```

(Resources are wired in Task 13 when `Bravura.otf` moves; for now this is a code-only target.)

Add `"SheetMusicLayoutApple"` to the non-Android `SheetMusicTests` dependencies list (the `isAndroid ? […] : […]` ternary), alphabetised:

```swift
dependencies: isAndroid ? [
    // unchanged
] : [
    "SheetMusic",
    "SheetMusicCore",
    "SheetMusicMIDI",
    "SheetMusicMSCX",
    "SheetMusicMusicXML",
    "SheetMusicLayout",
    "SheetMusicLayoutApple",   // NEW
    "SheetMusicUI",
    "SheetMusicAudio",
    "SheetMusicPDF",
    "SheetMusicXMLTools",
    "SheetMusicZip",
    .product(name: "ZIPFoundation", package: "ZIPFoundation"),
],
```

- [ ] **Step 2: Create placeholder source so SwiftPM accepts the empty target**

Create `Sources/SheetMusicLayoutApple/_Placeholder.swift`:

```swift
// Placeholder. Real sources land in Tasks 4–5 (provider + install).
// Deleted in Task 5.
```

- [ ] **Step 3: Verify Package resolves and builds**

```
swift build
swift test
```

Expected: both PASS. The new target is empty but compiles.

- [ ] **Step 4: Commit**

```bash
git add Package.swift Sources/SheetMusicLayoutApple/_Placeholder.swift
git commit -m "build: scaffold empty SheetMusicLayoutApple target"
```

---

## Task 4: Implement `AppleFontMetricsProvider` (TDD)

**Files:**
- Create: `Sources/SheetMusicLayoutApple/AppleFontMetricsProvider.swift`
- Test: `Tests/SheetMusicTests/Layout/AppleFontMetricsProviderTests.swift`

This task uses the existing `Bravura.otf` resource via `BravuraFont.register`. `BravuraFont` is still in `SheetMusicLayout/Fonts/` at this stage — Task 12 moves it. The provider therefore temporarily imports `SheetMusicLayout` and calls `BravuraFont.register` from there. Task 12 changes the import.

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/Layout/AppleFontMetricsProviderTests.swift`:

```swift
import CoreGraphics
import Foundation
import Testing
@testable import SheetMusicLayout
@testable import SheetMusicLayoutApple

@Suite("AppleFontMetricsProvider")
struct AppleFontMetricsProviderTests {
    private let provider = AppleFontMetricsProvider()
    private let bravuraEm = LayoutFont(face: "Bravura", pointSize: 4)

    @Test func ascentIsPositiveForBravura() {
        // Bravura's font-wide ascent should be well above zero at any
        // point size. Exact value is font-dependent — assert positivity
        // and rough scale only.
        let a = provider.ascent(font: bravuraEm)
        #expect(a > 0)
        #expect(a < 20)
    }

    @Test func descentIsPositiveForBravura() {
        let d = provider.descent(font: bravuraEm)
        #expect(d > 0)
        #expect(d < 20)
    }

    @Test func fermataAboveHasGlyphBoundingBox() {
        // U+E4C0 = fermataAbove. The glyph exists in Bravura with a
        // non-trivial bounding box.
        let bbox = provider.glyphPathBoundingBox(
            font: bravuraEm, codepoint: 0xE4C0,
        )
        #expect(bbox != nil)
        if let bbox {
            #expect(bbox.width > 0)
            #expect(bbox.height > 0)
        }
    }

    @Test func missingCodepointReturnsNil() {
        // 0xE000 is brace — exists. 0x0001 (SOH) does not exist as a
        // SMuFL glyph in Bravura; provider should report nil.
        let bbox = provider.glyphPathBoundingBox(
            font: bravuraEm, codepoint: 0x0001,
        )
        #expect(bbox == nil)
    }

    @Test func typographicWidthIsPositiveForKnownString() {
        let font = LayoutFont(face: "", pointSize: 10, weight: .semibold)
        let w = provider.typographicWidth(text: "Pa", font: font)
        #expect(w > 0)
    }

    @Test func inkBoundsHaveNonZeroWidth() {
        let font = LayoutFont(face: "", pointSize: 12)
        let ink = provider.inkBounds(text: "C7", font: font)
        #expect(ink.width > 0)
    }

    @Test func providerIsParallelSafe() async {
        // Stress the internal lock: same provider called from many
        // concurrent tasks shouldn't deadlock or crash.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    _ = provider.glyphPathBoundingBox(
                        font: bravuraEm, codepoint: 0xE4C0,
                    )
                    _ = provider.typographicWidth(
                        text: "Cm7", font: LayoutFont(face: "", pointSize: 12),
                    )
                }
            }
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```
swift test --filter AppleFontMetricsProviderTests
```

Expected: FAIL — `AppleFontMetricsProvider` not found.

- [ ] **Step 3: Implement the provider**

Create `Sources/SheetMusicLayoutApple/AppleFontMetricsProvider.swift`:

```swift
import CoreGraphics
import CoreText
import Foundation
import SheetMusicLayout

/// CoreText-backed `FontMetricsProvider`. Wraps the entire CT path in
/// a single `NSLock` because `CTFontCreateWithName` for unregistered
/// family names deadlocks under concurrent access (Swift Testing runs
/// test cases in parallel). The lock also serialises an internal
/// `[LayoutFont: CTFont]` cache — consolidates the per-file caches
/// (`BraceMetrics.bboxCache`, `FermataGlyphMetrics.cache`,
/// `HarmonyRendering.fontCache`) that the Layout-side rewrites
/// remove.
@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
public struct AppleFontMetricsProvider: FontMetricsProvider {
    public init() {
        // Touch BravuraFont.register so SMuFL family resolves
        // before any CT calls. Idempotent (static let).
        _ = BravuraFont.register
    }

    public func ascent(font: LayoutFont) -> CGFloat {
        Lock.shared.with {
            CTFontGetAscent(ctFont(for: font))
        }
    }

    public func descent(font: LayoutFont) -> CGFloat {
        Lock.shared.with {
            CTFontGetDescent(ctFont(for: font))
        }
    }

    public func glyphPathBoundingBox(
        font: LayoutFont, codepoint: UInt16,
    ) -> CGRect? {
        Lock.shared.with {
            let ct = ctFont(for: font)
            var unichars: [UniChar] = [codepoint]
            var glyphs: [CGGlyph] = [0]
            guard CTFontGetGlyphsForCharacters(
                ct, &unichars, &glyphs, 1,
            ), glyphs[0] != 0,
                let path = CTFontCreatePathForGlyph(ct, glyphs[0], nil)
            else { return nil }
            return path.boundingBox
        }
    }

    public func typographicWidth(
        text: String, font: LayoutFont,
    ) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        return Lock.shared.with {
            let line = ctLine(text: text, font: font)
            return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
    }

    public func inkBounds(text: String, font: LayoutFont) -> InkBounds {
        guard !text.isEmpty else { return InkBounds(leftBearing: 0, width: 0) }
        return Lock.shared.with {
            let line = ctLine(text: text, font: font)
            let image = CTLineGetImageBounds(line, nil)
            return InkBounds(
                leftBearing: image.origin.x,
                width: image.width,
            )
        }
    }

    // MARK: - Private

    /// Builds (or reuses) a `CTFont` for the requested face/size/weight.
    /// Caller must hold `Lock.shared`.
    private func ctFont(for font: LayoutFont) -> CTFont {
        if let cached = Cache.shared.ctFonts[font] { return cached }
        let new = makeCTFont(font: font)
        Cache.shared.ctFonts[font] = new
        return new
    }

    private func makeCTFont(font: LayoutFont) -> CTFont {
        if font.face.isEmpty {
            // System font with optional weight trait.
            let weight: CGFloat
            switch font.weight {
            case .regular: weight = 0
            case .semibold: weight = 0.3  // matches UIFont.Weight.semibold
            }
            let traits: CFDictionary = [
                kCTFontWeightTrait: weight,
            ] as CFDictionary
            let attributes: CFDictionary = [
                kCTFontTraitsAttribute: traits,
                kCTFontSizeAttribute: font.pointSize,
            ] as CFDictionary
            let descriptor = CTFontDescriptorCreateWithAttributes(attributes)
            return CTFontCreateWithFontDescriptor(
                descriptor, font.pointSize, nil,
            )
        }
        return CTFontCreateWithName(
            font.face as CFString, font.pointSize, nil,
        )
    }

    private func ctLine(text: String, font: LayoutFont) -> CTLine {
        let ct = ctFont(for: font)
        let attr = NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): ct,
            ],
        )
        return CTLineCreateWithAttributedString(attr as CFAttributedString)
    }
}

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
private final class Lock: @unchecked Sendable {
    static let shared = Lock()
    private let mutex = NSLock()
    func with<T>(_ body: () -> T) -> T {
        mutex.lock()
        defer { mutex.unlock() }
        return body()
    }
}

@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
private final class Cache: @unchecked Sendable {
    static let shared = Cache()
    var ctFonts: [LayoutFont: CTFont] = [:]
}
```

- [ ] **Step 4: Remove the placeholder file**

```bash
rm Sources/SheetMusicLayoutApple/_Placeholder.swift
```

- [ ] **Step 5: Run test to verify it passes**

```
swift test --filter AppleFontMetricsProviderTests
```

Expected: PASS (7 tests).

- [ ] **Step 6: Run the full suite**

```
swift test
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/SheetMusicLayoutApple/AppleFontMetricsProvider.swift \
        Tests/SheetMusicTests/Layout/AppleFontMetricsProviderTests.swift
git rm Sources/SheetMusicLayoutApple/_Placeholder.swift
git commit -m "feat(layout-apple): add AppleFontMetricsProvider with locked CT pipeline"
```

---

## Task 5: Implement `SheetMusicLayoutApple.install` (TDD)

**Files:**
- Create: `Sources/SheetMusicLayoutApple/SheetMusicLayoutApple.swift`
- Test: `Tests/SheetMusicTests/Layout/SheetMusicLayoutAppleInstallTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/Layout/SheetMusicLayoutAppleInstallTests.swift`:

```swift
import Foundation
import Testing
@testable import SheetMusicLayout
@testable import SheetMusicLayoutApple

@Suite("SheetMusicLayoutApple.install", .serialized)
struct SheetMusicLayoutAppleInstallTests {
    @Test func installSwapsProviderToApple() {
        // Reset state so the test is meaningful regardless of order.
        FontMetrics.provider = StubFontMetricsProvider()
        _ = SheetMusicLayoutApple.install
        #expect(FontMetrics.provider is AppleFontMetricsProvider)
    }

    @Test func installIsIdempotent() {
        FontMetrics.provider = StubFontMetricsProvider()
        _ = SheetMusicLayoutApple.install
        let first = type(of: FontMetrics.provider)
        // Second touch: the static let returns its cached value, no
        // additional swap happens. If someone reassigned provider in
        // the meantime, install does NOT clobber it (that is by
        // design — second touch is a no-op).
        _ = SheetMusicLayoutApple.install
        let second = type(of: FontMetrics.provider)
        #expect(String(describing: first) == String(describing: second))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```
swift test --filter SheetMusicLayoutAppleInstallTests
```

Expected: FAIL — `SheetMusicLayoutApple.install` not found.

- [ ] **Step 3: Implement install**

Create `Sources/SheetMusicLayoutApple/SheetMusicLayoutApple.swift`:

```swift
import Foundation
import SheetMusicLayout

/// Auto-installable façade for the Apple CoreText backend of
/// `SheetMusicLayout`.
///
/// Touch `SheetMusicLayoutApple.install` (via `_ =
/// SheetMusicLayoutApple.install`) at app launch or in the entry
/// point of any code path that constructs a `LayoutEngine` /
/// `ScoreView` / PDF export. The first touch sets
/// `FontMetrics.provider` to `AppleFontMetricsProvider`; subsequent
/// touches are free (`static let` caches the boolean result).
///
/// `SheetMusicUI` and `SheetMusicPDF` call this in their entry
/// points so Apple host apps don't need to invoke it explicitly.
/// Headless Layout consumers (`RenderPreviews`, isolated Layout
/// tests) call it themselves.
@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, *)
public enum SheetMusicLayoutApple {
    public static let install: Bool = {
        FontMetrics.provider = AppleFontMetricsProvider()
        return true
    }()
}
```

- [ ] **Step 4: Run test to verify it passes**

```
swift test --filter SheetMusicLayoutAppleInstallTests
```

Expected: PASS (2 tests).

- [ ] **Step 5: Run the full suite**

```
swift test
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicLayoutApple/SheetMusicLayoutApple.swift \
        Tests/SheetMusicTests/Layout/SheetMusicLayoutAppleInstallTests.swift
git commit -m "feat(layout-apple): add SheetMusicLayoutApple.install entry point"
```

---

## Task 6: Rewrite `BraceMetrics` to use `FontMetrics.provider`

**Files:**
- Modify: `Sources/SheetMusicLayout/Fonts/BraceMetrics.swift`

- [ ] **Step 1: Rewrite the file**

Replace the entire contents of `Sources/SheetMusicLayout/Fonts/BraceMetrics.swift` with:

```swift
import CoreGraphics
import Foundation

/// Brace SMuFL glyph metrics needed at layout time.
///
/// Mirrors `engraving/dom/bracket.cpp::Bracket::computeMagx` (`magx`
/// formula) and the Bravura brace-variant table that the SheetMusicUI
/// renderer also consults — exposing the same numbers in the layout
/// layer so the part-label gutter can reserve enough horizontal space
/// for tall braces (where the rendered glyph extends much further left
/// than `bracketColumnCount × sp`).
public enum BraceMetrics {
    // SMuFL brace glyph variants — Bravura's PUA range. Same set as
    // `SMuFLGlyph.braceVariant` in SheetMusicUI; duplicated here so the
    // layout target doesn't depend on the renderer module.
    private static let braceSmall: UInt16 = 0xF400
    private static let brace: UInt16 = 0xE000
    private static let braceLarge: UInt16 = 0xF401
    private static let braceLarger: UInt16 = 0xF402

    /// `(codepoint, magx)` for the given staff span, matching MuseScore's
    /// `Bracket::computeMagx`:
    ///   v=1 → braceSmall, v=2 → brace, v=3 → braceLarge, v≥4 → braceLarger.
    /// `magx = v + (v − 1) × 1.625` for v ≥ 2; 1 for v = 1.
    public static func variant(
        staffCount: Int,
    ) -> (codepoint: UInt16, magx: CGFloat) {
        let v = max(staffCount, 1)
        let magx: CGFloat = v == 1
            ? 1
            : CGFloat(v) + CGFloat(v - 1) * 1.625
        let codepoint: UInt16
        switch v {
        case 1: codepoint = braceSmall
        case 2: codepoint = brace
        case 3: codepoint = braceLarge
        default: codepoint = braceLarger
        }
        return (codepoint, magx)
    }

    /// Horizontal extent of the rendered brace glyph for a span of
    /// `staffCount` staves at the given `sp`. Equals
    /// `bbox.width × magx` where `bbox.width` is the variant glyph's
    /// natural bounding-box width measured at `fontSize = sp × 4`
    /// (Bravura's 1 em = 4 sp).
    public static func glyphHorizontalExtent(
        staffCount: Int, sp: CGFloat,
    ) -> CGFloat {
        let (codepoint, magx) = variant(staffCount: staffCount)
        let naturalAtUnitSp = naturalBBoxWidth(codepoint: codepoint)
        return naturalAtUnitSp * sp * magx
    }

    /// Natural bbox.width measured at `fontSize = 4` (i.e. sp = 1) so
    /// the cached value is in sp-units; callers scale by their own sp.
    /// Provider owns its own per-(face,size) cache, so we just ask
    /// each time — no local cache needed.
    private static func naturalBBoxWidth(codepoint: UInt16) -> CGFloat {
        let bbox = FontMetrics.provider.glyphPathBoundingBox(
            font: LayoutFont(face: SMuFLFamily.bravura, pointSize: 4),
            codepoint: codepoint,
        )
        return bbox?.width ?? 0
    }
}
```

Changes from the previous version:
- Drop `import CoreText`.
- Drop `@available(macOS 15.0, *)` (Layout is no longer Apple-gated).
- Replace the CT-direct `measureNaturalBBoxWidth` body with a single
  `FontMetrics.provider.glyphPathBoundingBox(...)` call.
- Remove `bboxLock` and `bboxCache` (provider owns caching).

- [ ] **Step 2: Verify the test suite**

```
swift test
```

Expected: PASS. Brace-related layout tests (look for `Bracket` /
`Brace` in test names) should be green using the Apple provider when
running on macOS — but note `SheetMusicLayoutApple.install` has not
been wired into `ScoreView`/`PDFExporter` yet (Tasks 14–15), so
test-time Bravura measurement falls back to Stub for code paths that
don't explicitly install. If any test fails because of degraded Stub
metrics, the path forward is to install the Apple provider at the
top of `Tests/SheetMusicTests/Helpers/TestSupport.swift` (or
equivalent suite-level setup). Apply this fix only if tests actually
fail — most tests don't depend on exact brace widths.

If a test does fail, add to (or create) `Tests/SheetMusicTests/Helpers/TestSupport.swift`:

```swift
import Foundation
@testable import SheetMusicLayout
@testable import SheetMusicLayoutApple

enum TestSupport {
    static let installApple: Bool = {
        _ = SheetMusicLayoutApple.install
        return true
    }()
}
```

And touch `_ = TestSupport.installApple` at the top of the failing test suite. Commit this fix in the same task.

- [ ] **Step 3: Commit**

```bash
git add Sources/SheetMusicLayout/Fonts/BraceMetrics.swift
# Plus TestSupport.swift if you needed Step 2's fix
git commit -m "refactor(layout): route BraceMetrics through FontMetrics.provider"
```

---

## Task 7: Rewrite `FermataGlyphMetrics` to use `FontMetrics.provider`

**Files:**
- Modify: `Sources/SheetMusicLayout/Fonts/FermataGlyphMetrics.swift`

- [ ] **Step 1: Rewrite the file**

Replace contents of `Sources/SheetMusicLayout/Fonts/FermataGlyphMetrics.swift`:

```swift
import CoreGraphics
import Foundation

/// Per-glyph offsets describing where the visible glyph sits relative
/// to `origin.y` when `Text(glyph)` is drawn with anchor `.center`
/// (the convention used by `GraphicsContext.drawGlyph` and
/// `ScoreLayerBuilder.glyphLayer`). Positive Y = lower on screen
/// (CG screen-Y-down).
///
/// All values are at `fontSize = 4` (i.e. 1 sp = 1 unit), so callers
/// scale by their own `metrics.sp`.
public struct FermataGlyphOffsets: Sendable {
    public let bottomOffset: CGFloat
    public let topOffset: CGFloat
}

/// Runtime-measured offsets for the SMuFL fermata glyphs in Bravura.
///
/// The layout engine uses these to position the fermata `origin.y`
/// such that the visible glyph EDGE — not its typographic bbox —
/// clears the chord skyline by a known gap.
public enum FermataGlyphMetrics {
    /// fermataAbove (U+E4C0).
    public static var above: FermataGlyphOffsets {
        offsets(for: 0xE4C0)
    }

    /// fermataBelow (U+E4C1).
    public static var below: FermataGlyphOffsets {
        offsets(for: 0xE4C1)
    }

    private static func offsets(for codepoint: UInt16) -> FermataGlyphOffsets {
        let bravuraEm = LayoutFont(face: SMuFLFamily.bravura, pointSize: 4)
        let provider = FontMetrics.provider
        let ascent = provider.ascent(font: bravuraEm)
        let descent = provider.descent(font: bravuraEm)
        // Anchor .center puts the text view's typographic CENTRE at
        // origin.y. Text view height = ascent + descent. The baseline
        // therefore sits `(ascent - descent) / 2` BELOW origin in
        // screen-Y-down coords.
        let baselineFromCenter = (ascent - descent) / 2
        guard let bbox = provider.glyphPathBoundingBox(
            font: bravuraEm, codepoint: codepoint,
        ) else {
            // Defensive fallback (provider has no glyph for codepoint).
            return FermataGlyphOffsets(
                bottomOffset: baselineFromCenter,
                topOffset: baselineFromCenter - 0.7,
            )
        }
        return FermataGlyphOffsets(
            bottomOffset: baselineFromCenter - bbox.minY,
            topOffset: baselineFromCenter - bbox.maxY,
        )
    }
}
```

Changes:
- Drop `import CoreText`, `@available` annotation.
- Replace `measure(codepoint:)` CT body with provider calls.
- Drop `lock` and `cache` (provider owns caching).

- [ ] **Step 2: Verify**

```
swift test
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Sources/SheetMusicLayout/Fonts/FermataGlyphMetrics.swift
git commit -m "refactor(layout): route FermataGlyphMetrics through FontMetrics.provider"
```

---

## Task 8: Rewrite `LayoutEngine+Lyrics.lyricsTextWidth` to use provider

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Lyrics.swift`

- [ ] **Step 1: Replace the `lyricsTextWidth` body and drop `import CoreText`**

In `Sources/SheetMusicLayout/Layout/LayoutEngine+Lyrics.swift`:

1. Delete the line `import CoreText` near the top of the file.
2. Replace the body of `lyricsTextWidth(_:sp:)` (currently uses
   `CTFontDescriptor` + `CTLine`) with:

```swift
static func lyricsTextWidth(
    _ text: String, sp: CGFloat,
) -> CGFloat {
    guard !text.isEmpty else { return 0 }
    // Lyrics render at .semibold to match
    // GraphicsContext+Glyph.drawExpressionText. Provider resolves
    // the system font + weight trait internally.
    return FontMetrics.provider.typographicWidth(
        text: text,
        font: LayoutFont(face: "", pointSize: sp * 2.2, weight: .semibold),
    )
}
```

- [ ] **Step 2: Verify**

```
swift test
```

Expected: PASS. Lyrics-spacing tests should still be tight enough not
to regress with the Apple provider once install is wired. If they
fail in this transient state, refer to Task 6 Step 2's TestSupport
workaround.

- [ ] **Step 3: Commit**

```bash
git add Sources/SheetMusicLayout/Layout/LayoutEngine+Lyrics.swift
git commit -m "refactor(layout): route lyricsTextWidth through FontMetrics.provider"
```

---

## Task 9: Rewrite `HarmonyRendering` to use provider; remove `ctLock` and `fontCache`

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/HarmonyRendering.swift`

- [ ] **Step 1: Apply changes**

In `Sources/SheetMusicLayout/Layout/HarmonyRendering.swift`:

1. Delete the line `import CoreText` at the top.
2. Delete the `_ = BravuraFont.register` call inside `runs(for:metrics:)`
   (provider's `init` does this).
3. Delete the `ctLock.lock() / defer { ctLock.unlock() }` lines —
   provider serialises internally.
4. Delete the `ctLock` static property declaration.
5. Delete the `fontCache` static property and the `makeFont(face:pointSize:)`
   helper that consults it.
6. Replace any `let textFont = makeFont(face: …, pointSize: textSize)` and
   `let glyphFont = makeFont(face: "Bravura", pointSize: glyphSize)` with
   `LayoutFont` value-type constructions:

```swift
let textFont = LayoutFont(
    face: textFace(for: harmony), pointSize: textSize,
)
let glyphFont = LayoutFont(
    face: SMuFLFamily.bravura, pointSize: glyphSize,
)
```

7. Replace the existing `inkBounds(_:font:) -> (Double, Double)` and
   `ctLine(for:font:) -> CTLine` helpers with provider calls. The
   call sites change from `inkBounds(slice.text, font: textFont)`
   (returning `(leftBearing:Double, width:Double)`) to:

```swift
let bounds = FontMetrics.provider.inkBounds(
    text: slice.text, font: textFont,
)
let leftBearing = bounds.leftBearing
let width = bounds.width
```

   (Variable types change `Double → CGFloat`; downstream `cursor +=
   width + textGap` math is `CGFloat`-compatible already.)

8. If any other helper relies on `CTLineGetTypographicBounds` for
   advance (rather than ink bounds), replace with
   `FontMetrics.provider.typographicWidth(text:font:)`.

9. Drop `@available(macOS 15.0, *)` annotation on `HarmonyRendering`
   if it has one.

The file should no longer contain any of: `CTFont`, `CTLine`,
`CTLineCreate`, `CTLineGetImageBounds`, `CTLineGetTypographicBounds`,
`CFAttributedString`, `kCT…`, `ctLock`, `fontCache`. Confirm with:

```
grep -n 'CT\|kCT\|ctLock\|fontCache' Sources/SheetMusicLayout/Layout/HarmonyRendering.swift
```

Expected: no output.

- [ ] **Step 2: Verify**

```
swift test
```

Expected: PASS. Harmony / chord-symbol tests (look for `Harmony`,
`ChordSymbol`) must stay green. If they regress because Stub provider
is in use during tests, install via TestSupport (see Task 6 Step 2).

- [ ] **Step 3: Commit**

```bash
git add Sources/SheetMusicLayout/Layout/HarmonyRendering.swift
git commit -m "refactor(layout): route HarmonyRendering through FontMetrics.provider"
```

---

## Task 10: Remove dead `import CoreText` from `LayoutEngine+Placement`

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift`

- [ ] **Step 1: Delete the unused import**

Delete the line `import CoreText` at the top of
`Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift`.

Sanity-check with grep first:

```
grep -n 'CT\|kCT' Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift
```

Expected: only the `import CoreText` line (no actual CT calls). If
there are unexpected matches, route them through `FontMetrics.provider`
as in Tasks 8 / 9.

- [ ] **Step 2: Verify**

```
swift build
swift test
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Sources/SheetMusicLayout/Layout/LayoutEngine+Placement.swift
git commit -m "refactor(layout): drop dead CoreText import from LayoutEngine+Placement"
```

---

## Task 11: Confirm Layout target has zero CoreText / CTFontManager surface

This is a verification-only task — no code changes if Tasks 6–10
were thorough.

- [ ] **Step 1: Search for any remaining CoreText use in `SheetMusicLayout`**

```
grep -rn 'import CoreText\|CTFont\|CTLine\|CTFontManager\|kCT' \
    Sources/SheetMusicLayout/
```

Expected output: **only** matches inside `BravuraFont.swift` and
`SheetMusicFonts.swift` (those files move in Tasks 12–13). No matches
in `Layout/`, `Fonts/BraceMetrics.swift`, `Fonts/FermataGlyphMetrics.swift`,
or `FontMetricsProvider.swift`.

If unexpected matches appear, port the relevant call through
`FontMetrics.provider` before continuing.

- [ ] **Step 2: Run full suite**

```
swift test
```

Expected: PASS.

No commit needed (verification only).

---

## Task 12: Move `BravuraFont` from `SheetMusicLayout` to `SheetMusicLayoutApple`

**Files:**
- Delete: `Sources/SheetMusicLayout/Fonts/BravuraFont.swift`
- Create: `Sources/SheetMusicLayoutApple/BravuraFont.swift` (same contents, see notes)

- [ ] **Step 1: Move the file and update the bundle lookup string**

```bash
git mv Sources/SheetMusicLayout/Fonts/BravuraFont.swift \
       Sources/SheetMusicLayoutApple/BravuraFont.swift
```

In `Sources/SheetMusicLayoutApple/BravuraFont.swift`, find the
`forResource: "swift-sheet-music_SheetMusicUI"` string inside
`locateBravuraURL` and change it to:

```swift
if let nestedURL = bundle.url(
    forResource: "swift-sheet-music_SheetMusicLayoutApple",
    withExtension: "bundle",
),
```

The rest of the file (logger subsystem, `BundleAnchor`, `register`
static let, etc.) stays unchanged.

Update the logger subsystem string from
`"swift-sheet-music.SheetMusicUI"` to
`"swift-sheet-music.SheetMusicLayoutApple"`:

```swift
let logger = Logger(
    subsystem: "swift-sheet-music.SheetMusicLayoutApple",
    category: "BravuraFont",
)
```

- [ ] **Step 2: Build to confirm Layout no longer references `BravuraFont`**

```
swift build
```

Expected: PASS. If there is a reference left inside `Sources/SheetMusicLayout/`
the compile will fail — fix it by routing through `SMuFLFamily.bravura`
or `FontMetrics.provider`.

- [ ] **Step 3: Run the suite**

```
swift test
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/SheetMusicLayoutApple/BravuraFont.swift
git rm Sources/SheetMusicLayout/Fonts/BravuraFont.swift
git commit -m "refactor(layout-apple): move BravuraFont out of Foundation-only Layout"
```

---

## Task 13: Move `SheetMusicFonts` + `Bravura.otf` resource

**Files:**
- Delete: `Sources/SheetMusicLayout/Fonts/SheetMusicFonts.swift`
- Create: `Sources/SheetMusicLayoutApple/SheetMusicFonts.swift`
- Delete: `Sources/SheetMusicLayout/Fonts/Resources/Bravura.otf` (+ LICENSE)
- Create: `Sources/SheetMusicLayoutApple/Fonts/Resources/Bravura.otf` (+ LICENSE)
- Modify: `Package.swift`

- [ ] **Step 1: Move source file**

```bash
git mv Sources/SheetMusicLayout/Fonts/SheetMusicFonts.swift \
       Sources/SheetMusicLayoutApple/SheetMusicFonts.swift
```

Update the logger subsystem string at the top of the moved file:
`"swift-sheet-music.SheetMusicLayout"` → `"swift-sheet-music.SheetMusicLayoutApple"`.

- [ ] **Step 2: Move the Bravura resource directory**

```bash
mkdir -p Sources/SheetMusicLayoutApple/Fonts/Resources
git mv Sources/SheetMusicLayout/Fonts/Resources/Bravura.otf \
       Sources/SheetMusicLayoutApple/Fonts/Resources/Bravura.otf
```

If there is a `Bravura.LICENSE.txt` (check `ls Sources/SheetMusicLayout/Fonts/Resources/`):

```bash
git mv Sources/SheetMusicLayout/Fonts/Resources/Bravura.LICENSE.txt \
       Sources/SheetMusicLayoutApple/Fonts/Resources/Bravura.LICENSE.txt
```

Remove now-empty `Sources/SheetMusicLayout/Fonts/Resources/`:

```bash
rmdir Sources/SheetMusicLayout/Fonts/Resources
```

- [ ] **Step 3: Update `Package.swift` resource declarations**

In `Package.swift`:

1. Remove `resources: [.process("Fonts/Resources")]` from the
   `SheetMusicLayout` target (the resource directory is gone).
2. Add `resources: [.process("Fonts/Resources")]` to the
   `SheetMusicLayoutApple` target (added in Task 3, currently
   resource-less):

```swift
.target(
    name: "SheetMusicLayoutApple",
    dependencies: ["SheetMusicCore", "SheetMusicLayout"],
    resources: [.process("Fonts/Resources")],
),
```

- [ ] **Step 4: Build and test**

```
swift build
swift test
```

Expected: PASS. The resource bundle name SwiftPM generates is now
`swift-sheet-music_SheetMusicLayoutApple.bundle`, matching the
string updated in Task 12.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicLayoutApple/SheetMusicFonts.swift \
        Sources/SheetMusicLayoutApple/Fonts/Resources/ \
        Package.swift
git rm Sources/SheetMusicLayout/Fonts/SheetMusicFonts.swift
git commit -m "refactor(layout-apple): move SheetMusicFonts + Bravura.otf resource"
```

---

## Task 14: Wire `SheetMusicUI` auto-install

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/SheetMusicUI/ScoreView.swift`

- [ ] **Step 1: Add LayoutApple dep**

In `Package.swift`, change the `SheetMusicUI` target dependencies:

```swift
.target(
    name: "SheetMusicUI",
    dependencies: [
        "SheetMusicCore",
        "SheetMusicLayout",
        "SheetMusicLayoutApple",   // NEW
    ],
),
```

- [ ] **Step 2: Swap registration call in both `ScoreView.init` overloads**

In `Sources/SheetMusicUI/ScoreView.swift`:

1. Add `import SheetMusicLayoutApple` to the import list.
2. In both `init` overloads (the two `_ = BravuraFont.register` lines
   at the top of each), replace with:

```swift
_ = SheetMusicLayoutApple.install
```

(`install` internally touches `BravuraFont.register`, so there is no
need to keep the old line as well.)

- [ ] **Step 3: Verify**

```
swift build
swift test
```

Expected: PASS. With install now wired, the lock-stress test from
Task 4 and all UI/Layout tests run with the real Apple provider.

- [ ] **Step 4: Commit**

```bash
git add Package.swift Sources/SheetMusicUI/ScoreView.swift
git commit -m "feat(ui): auto-install SheetMusicLayoutApple from ScoreView.init"
```

---

## Task 15: Wire `SheetMusicPDF` auto-install

**Files:**
- Modify: `Package.swift`
- Modify: `Sources/SheetMusicPDF/PDFExporter.swift`

- [ ] **Step 1: Add LayoutApple dep**

In `Package.swift`, add to the `SheetMusicPDF` target dependencies:

```swift
.target(
    name: "SheetMusicPDF",
    dependencies: [
        "SheetMusicCore",
        "SheetMusicLayout",
        "SheetMusicLayoutApple",   // NEW
        "SheetMusicUI",
    ],
),
```

- [ ] **Step 2: Swap registration call**

In `Sources/SheetMusicPDF/PDFExporter.swift`:

1. Add `import SheetMusicLayoutApple`.
2. Replace `_ = BravuraFont.register` (around line 94) with
   `_ = SheetMusicLayoutApple.install`.
3. If the second `public static func export` overload around line 179
   also calls `BravuraFont.register`, swap that one too. (Check
   with grep: `grep -n 'BravuraFont.register'
   Sources/SheetMusicPDF/PDFExporter.swift`. The first task-1
   exploration showed only one occurrence; verify here.)

- [ ] **Step 3: Verify**

```
swift build
swift test
```

Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Package.swift Sources/SheetMusicPDF/PDFExporter.swift
git commit -m "feat(pdf): auto-install SheetMusicLayoutApple from PDFExporter"
```

---

## Task 16: Add DEBUG guard inside `LayoutEngine.layout(...)`

**Files:**
- Modify: `Sources/SheetMusicLayout/Layout/LayoutEngine.swift`

- [ ] **Step 1: Insert guard**

In `Sources/SheetMusicLayout/Layout/LayoutEngine.swift`, at the top
of the function-body-length `layout(score:options:availableWidth:cache:)`
method (the cache-aware overload — the other overload calls into it),
add the guard as the very first statement:

```swift
public static func layout( // swiftlint:disable:this function_body_length
    score: Score,
    options: ScoreViewOptions,
    availableWidth: CGFloat,
    cache: LayoutCache?,
) -> LayoutDocument {
    #if DEBUG && canImport(CoreText)
    assert(
        !(FontMetrics.provider is StubFontMetricsProvider),
        "FontMetrics.provider is still StubFontMetricsProvider on a "
        + "CoreText-capable platform. Call "
        + "`_ = SheetMusicLayoutApple.install` at app launch, or "
        + "import SheetMusicUI / SheetMusicPDF (they auto-install).",
    )
    #endif
    let metrics = StaffMetrics(staffSize: options.staffSize)
    // … existing body
```

(Drop `@available(macOS 15.0, *)` on `LayoutEngine` if it survived
the audit. Task 23 cleans up any remaining availability annotations.)

- [ ] **Step 2: Verify all tests still pass**

```
swift test
```

Expected: PASS. Tests that previously installed the Apple provider
(via ScoreView/PDFExporter or TestSupport from Task 6) continue to
work. Any test that constructs `LayoutEngine.layout(...)` directly
without going through UI/PDF must touch `_ =
SheetMusicLayoutApple.install` (or `_ = TestSupport.installApple`) —
the assert will fire otherwise. Fix on a per-test basis.

- [ ] **Step 3: Commit**

```bash
git add Sources/SheetMusicLayout/Layout/LayoutEngine.swift \
        Tests/SheetMusicTests/  # any test files patched for install
git commit -m "feat(layout): assert non-stub provider in LayoutEngine on CoreText platforms"
```

---

## Task 17: Wire `RenderPreviews` install

**Files:**
- Modify: `Sources/RenderPreviews/main.swift`

- [ ] **Step 1: Add import + install**

In `Sources/RenderPreviews/main.swift`:

1. Add `import SheetMusicLayoutApple` next to the existing
   `import SheetMusicLayout`.
2. Replace `_ = BravuraFont.register` (in `run()`) with
   `_ = SheetMusicLayoutApple.install`.

- [ ] **Step 2: Verify Build**

```
swift build --target render-previews
```

Expected: PASS.

- [ ] **Step 3: Smoke-run RenderPreviews**

```
swift run render-previews /tmp/preview-smoke
ls /tmp/preview-smoke/
```

Expected: a directory of PNGs (01-empty.png, 02-whole-note.png, etc).
The Mac Example app visual smoke comes in Task 18.

- [ ] **Step 4: Commit**

```bash
git add Sources/RenderPreviews/main.swift
git commit -m "feat(render-previews): auto-install Apple Layout provider"
```

---

## Task 18: Hoist `SheetMusicLayout` product to Android-visible

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Move `SheetMusicLayout` product out of `if !isAndroid`**

In `Package.swift`:

1. Add `.library(name: "SheetMusicLayout", targets: ["SheetMusicLayout"])`
   to the unconditional `products` array at the top.
2. Remove it from the `if !isAndroid` block (if it was there). The
   `SheetMusicLayout` target itself stays in the unconditional
   `targets` array (it is already there from Task 6 onwards because
   it has no Apple-only deps).
3. Add `"SheetMusicLayout"` to the `isAndroid ? […]` Android branch
   of `SheetMusicTests` dependencies (alphabetised next to
   `SheetMusicMSCX`).

- [ ] **Step 2: Verify host Apple build still works**

```
swift build
swift test
```

Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Package.swift
git commit -m "build: expose SheetMusicLayout product on Android"
```

---

## Task 19: Sweep Apple-only imports in `SheetMusicLayout` for Android compile

**Files:**
- Modify: any `Sources/SheetMusicLayout/**/*.swift` files surfaced by
  the audit below.

- [ ] **Step 1: Audit `os` (Logger) usage**

```
grep -rn 'import os\|Logger(' Sources/SheetMusicLayout/
```

For each match:
- If the file is now Foundation-only (after Tasks 6–13), wrap the
  `import os` line and any `Logger(...)` declarations in
  `#if canImport(os) … #endif`. For each `logger.info(...)` call
  site, gate with the same `#if` (or define a no-op stub helper
  if the file has many call sites).

If after Tasks 6–13 there are no `os.Logger` users left in Layout
(BravuraFont/SheetMusicFonts have moved out), this step is a no-op.

- [ ] **Step 2: Audit `CoreGraphics` import availability**

```
grep -rln 'import CoreGraphics' Sources/SheetMusicLayout/
```

CoreGraphics types (`CGFloat`, `CGRect`, `CGPoint`, `CGSize`,
`CGAffineTransform`) ARE expected to resolve via Foundation on the
Swift Android SDK (swift-corelibs-foundation re-exports). Do NOT
preemptively gate `import CoreGraphics` — wait for actual Android
compile errors in Task 20 / 22 and address them surgically.

- [ ] **Step 3: Audit other Apple frameworks**

```
grep -rn 'import \(AppKit\|UIKit\|SwiftUI\|QuartzCore\|AVFoundation\|PDFKit\)' \
    Sources/SheetMusicLayout/
```

Expected: no matches. If any appear, gate with `#if canImport(<framework>)`
or move the file to `SheetMusicLayoutApple`.

- [ ] **Step 4: Verify host Apple build still works**

```
swift build
swift test
```

Expected: PASS.

- [ ] **Step 5: Commit (only if files changed)**

```bash
git add Sources/SheetMusicLayout/
git commit -m "refactor(layout): gate Apple-only imports for Android compile"
```

If nothing was changed, skip the commit and move on.

---

## Task 20: Verify Android cross-compile of `SheetMusicLayout`

**Files:** none (verification step)

This step actually invokes the Android cross-compile. If it surfaces
errors, fix them inline (gate imports, swap types, move code) and
re-run.

- [ ] **Step 1: Cross-compile**

Use the Phase 1 toolchain helper:

```
Scripts/android-test.sh
```

(Reads `SWIFT_SHEET_MUSIC_ANDROID=1` from inside the script.)

Expected: the script builds the Android target list — which now
includes `SheetMusicLayout` — and runs all Android-compatible tests
in the emulator. PASS = exit 0.

If you see errors:
- `cannot find type 'CGRect' in scope` etc → gate the import with
  `#if canImport(CoreGraphics)` and add `import Foundation` if
  missing.
- `cannot find 'Logger' in scope` → wrap with `#if canImport(os)`
  (see Task 19 Step 1).
- `value of type 'X' has no member 'Y'` for an Apple-only API →
  move the affected file to `SheetMusicLayoutApple` or gate the
  call site.

Fix and re-run until green.

- [ ] **Step 2: Capture the post-Phase 2 Android test count**

The script prints something like
`Test Suite 'All tests' passed at <time>; Executed N tests, …`.
Record the number for Task 23 (memory update).

- [ ] **Step 3: Verify host Apple build is still green**

```
swift test
```

Expected: PASS — fixes from Step 1 should not have regressed Apple.

- [ ] **Step 4: Commit Android compile fixes (only if Step 1 made changes)**

```bash
git add Sources/SheetMusicLayout/
git commit -m "fix(layout): unblock Android cross-compile"
```

---

## Task 21: Add Android Layout smoke test

**Files:**
- Create: `Tests/SheetMusicTests/Layout/LayoutEngineAndroidSmokeTests.swift`

This test runs on both host Apple and Android. It uses the
`midi01.mscx` fixture (already available under
`Tests/SheetMusicTests/Resources/`).

- [ ] **Step 1: Create the test**

```swift
import Foundation
import Testing
@testable import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicMSCX

@Suite("LayoutEngine — Android-compatible smoke")
struct LayoutEngineAndroidSmokeTests {
    @Test func midi01ScoreProducesNonEmptyLayoutDocument() throws {
        let url = try #require(
            Bundle.module.url(forResource: "midi01", withExtension: "mscx"),
        )
        let data = try Data(contentsOf: url)
        let score = try MSCXParser.parse(data: data)
        let document = LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(),
            availableWidth: 600,
        )
        #expect(!document.systems.isEmpty)
    }
}
```

- [ ] **Step 2: Verify host Apple build runs the test**

```
swift test --filter LayoutEngineAndroidSmokeTests
```

Expected: PASS.

NOTE: on host Apple, the existing Bravura provider is in use (because
auto-install ran via at-least-one ScoreView/PDFExporter call somewhere
in the test suite). If this test runs in isolation with no other
suite triggering install, the DEBUG assert from Task 16 will fire.
If that happens, add `_ = TestSupport.installApple` at the top of
the test function — but check first whether it is needed; the
`.serialized` install tests in Task 5 may have already done it for
the in-process FontMetrics.provider.

- [ ] **Step 3: Verify Android run**

```
Scripts/android-test.sh
```

Expected: the new smoke test appears in the suite count and passes.

- [ ] **Step 4: Commit**

```bash
git add Tests/SheetMusicTests/Layout/LayoutEngineAndroidSmokeTests.swift
git commit -m "test(layout): add Android-compatible Score→LayoutDocument smoke test"
```

---

## Task 22: Mac + iOS Example app build + visual smoke

**Files:** none (verification — may need a `cd Example && xcodegen generate`).

- [ ] **Step 1: Regenerate Example xcodeproj if needed**

Only if `Example/project.yml` has changed (in this branch we have not
touched it). Skip if untouched:

```
cd Example && xcodegen generate
```

- [ ] **Step 2: Build Mac Example**

```
xcodebuild -project Example/SheetMusicExample.xcodeproj \
    -scheme SheetMusicExampleMac \
    -skipPackagePluginValidation build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Build iOS Example**

```
xcodebuild -project Example/SheetMusicExample.xcodeproj \
    -scheme SheetMusicExample \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -skipPackagePluginValidation build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Manual visual smoke (Mac Example)**

Per `~/.claude/CLAUDE.md` "iOS / macOS app development" instructions:
verify in `SheetMusicExampleMac`, not the iOS simulator. Run the app
and check (one of each):

- A piece with chord symbols (e.g. Scarlatti K1) — accidentals and
  letters tightly typeset, no gaps.
- A multi-voice piece — beaming and ties unbroken.
- A piece with lyrics + melisma — syllables don't overlap on tight
  eighth-note runs.
- A multi-staff piece with a 3+ staff brace — brace renders correctly,
  part-label gutter wide enough.

Compare against pre-Phase-2 expectations. No new tofu boxes, no
unexplained gaps.

If something looks off, the most likely cause is `BravuraFont.find(in:)`
nested-bundle string mismatch (Task 12). Open the running app's
console and look for `Failed to register` / `not located via any
bundle strategy` logs.

- [ ] **Step 5: Confirm and commit (no code changes expected)**

Verification only — no commit unless a regression was found and
fixed.

---

## Task 23: Cleanup — availability annotations, docs, memory

**Files:**
- Modify: `Sources/SheetMusicLayout/**/*.swift` (strip
  `@available(macOS 15.0, *)`)
- Modify: `CLAUDE.md`
- Modify: `~/.claude/projects/-Users-kiichi-Developer-Personal-swift-packages-swift-sheet-music/memory/project_android_port_roadmap.md`

- [ ] **Step 1: Strip availability annotations from Layout public API**

Find them:

```
grep -rn '@available(macOS 15' Sources/SheetMusicLayout/
```

For each match in `Sources/SheetMusicLayout/`, delete the line. (Do
NOT touch `Sources/SheetMusicLayoutApple/` — those stay.)

Verify build + test:

```
swift test
```

Expected: PASS.

- [ ] **Step 2: Update `CLAUDE.md` Library layout**

In `CLAUDE.md`, find the "Library layout" diagram. Add
`SheetMusicLayoutApple` under the Apple-only group; ensure
`SheetMusicLayout` is in the cross-platform group. Concretely change
the diagram region from:

```
SheetMusicLayout      (pure-geometry layout; → Core)
SheetMusicUI          (SwiftUI views; → Core, Layout)
SheetMusicAudio       (AVFoundation playback + audio file export; → Core, MIDI)
SheetMusicPDF         (PDF export; → Core, Layout, UI)
```

to:

```
SheetMusicLayout      (pure-geometry layout, Foundation-only,
                       Android-compatible; → Core)
SheetMusicLayoutApple (CoreText font metrics provider for Layout;
                       Apple-only; → Core, Layout)
SheetMusicUI          (SwiftUI views; → Core, Layout, LayoutApple)
SheetMusicAudio       (AVFoundation playback + audio file export;
                       → Core, MIDI)
SheetMusicPDF         (PDF export; → Core, Layout, LayoutApple, UI)
```

Also locate the "Format support matrix" / Android section (added in
Phase 1) and confirm `SheetMusicLayout` is listed as Android-supported.

- [ ] **Step 3: Update roadmap memory**

Open
`~/.claude/projects/-Users-kiichi-Developer-Personal-swift-packages-swift-sheet-music/memory/project_android_port_roadmap.md`
and:

1. Update the `description:` field — mark Phase 2 completed (2026-MM-DD).
2. In the Phase 2 section body, replace the checklist with a "**Status:
   completed**" line and any salient learnings:
   - `SheetMusicLayoutApple` target landed; auto-install via UI/PDF.
   - StubFontMetricsProvider lives in Layout (rectangle approximations).
   - Bravura.otf moved to LayoutApple resource bundle (nested name:
     `swift-sheet-music_SheetMusicLayoutApple.bundle`).
   - Android test count: before N, after N+M (record from Task 20
     Step 2 / Task 21 Step 3).
3. Update the "Known unknowns" `os.Logger silent on Android` entry —
   note whether Phase 2 addressed it for Layout (most likely yes via
   Task 19 Step 1) and where it remains (`SheetMusicAudio` etc).

- [ ] **Step 4: Run final lint**

```
swiftlint --quiet Sources Tests
```

Expected: 0 warnings, 0 errors. Fix anything that surfaces (most
likely line-length nits from new files); commit fixes in this same
task.

- [ ] **Step 5: Final full-suite run**

```
swift test
Scripts/android-test.sh
```

Both expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicLayout/ CLAUDE.md
git commit -m "docs(layout): finalize Phase 2 — strip availability, update CLAUDE.md"
```

(Memory file is outside the repo — saved separately, not committed.)

---

## Definition of Done

All boxes checked:

- [ ] `swift build` (host Apple) green
- [ ] `swift test` (host Apple) green; new unit tests for Stub / Apple
      providers + install + DEBUG guard + Android smoke included
- [ ] `Scripts/android-test.sh` green; Layout suite contributes to
      the Android test count (recorded in memory)
- [ ] Mac + iOS Example app `xcodebuild` green
- [ ] Mac Example app manual visual smoke: chord symbols, multi-voice,
      lyrics + melisma, multi-staff brace — no regressions
- [ ] `swiftlint --quiet Sources Tests` — 0 warnings/errors
- [ ] `CLAUDE.md` (Library layout + Android matrix) updated
- [ ] Memory `project_android_port_roadmap.md` Phase 2 marked
      completed with new test count
