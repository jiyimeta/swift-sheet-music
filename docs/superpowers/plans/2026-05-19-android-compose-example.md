# Android Compose Example Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship an end-to-end Kotlin Compose example app under `Examples/Android/` that parses an `.mscz`, computes layout via a cross-compiled Swift JNI bridge, and renders pages onto a Compose `Canvas`. Audio is intentionally not wired — that work is deferred until Phase 3 (`audio-backend-di`) merges to `main`.

**Architecture:** New always-present Swift target `SheetMusicAndroidJNI` holds the JNI bridge code. JNI `@_cdecl` symbols are gated `#if os(Android)` so the encoder / handle-table logic can be unit-tested on Apple via `swift test`. The dynamic library product `SheetMusicJNI` is only registered when `SWIFT_SHEET_MUSIC_ANDROID=1`. `Examples/Android/` is a standalone Gradle project that links the cross-compiled `.so` files staged into `app/src/main/jniLibs/<abi>/`. LayoutDocument is transported across the JNI boundary as a flat little-endian "draw program" byte array; the Compose side decodes and replays it onto `DrawScope`.

**Tech Stack:** Swift 6.3.2-RELEASE (open-source toolchain), Swift Android SDK 6.3.2-RELEASE_android-0.1, Kotlin 2.0+ with Compose, Gradle 8.x, Android API 28+, NDK r27 (whichever Phase 1 staged), JDK 17.

**Reference spec:** `docs/superpowers/specs/2026-05-19-android-compose-example-design.md`

**Worktree:** `.claude/worktrees/android-compose-example` (branch `worktree-android-compose-example`), branched from local `main` HEAD per memory `feedback_worktree_layout`. Phase 3 runs in parallel under `.claude/worktrees/audio-backend-di`.

---

## File structure

**New Swift sources:**

```
Sources/SheetMusicAndroidJNI/
├── DrawProgram.swift              # opcodes, format constants, BinaryWriter / BinaryReader
├── DrawProgramEncoder.swift       # LayoutDocument → Data
├── DrawProgramDecoder.swift       # Data → [Page] (testing only; Kotlin owns the real decoder)
├── HandleTable.swift              # actor-backed [Int64: Any]
├── ScoreBridge.swift              # bytes → Score
├── LayoutBridge.swift             # Score + page size → encoded bytes
└── JNISymbols.swift               # @_cdecl entry points; #if os(Android) only
```

**New C-interop module (Android-only):**

```
Sources/CJNI/
├── module.modulemap
└── shim.h                         # #include <jni.h>
```

**New Swift tests (Apple host only):**

```
Tests/SheetMusicTests/AndroidJNI/
├── DrawProgramRoundTripTests.swift
├── HandleTableTests.swift
├── ScoreBridgeTests.swift
└── LayoutBridgeTests.swift
```

**New scripts:**

```
Scripts/
├── android-build-libs.sh
└── android-bundle-test-score.sh
```

**New Gradle project (`Examples/Android/`):**

```
Examples/Android/
├── .gitignore
├── README.md
├── build.gradle.kts                     # top-level (no plugins applied here)
├── settings.gradle.kts
├── gradle.properties
├── gradle/wrapper/{gradle-wrapper.jar, gradle-wrapper.properties}
├── gradlew, gradlew.bat
└── app/
    ├── build.gradle.kts                 # Android app module
    ├── proguard-rules.pro
    └── src/main/
        ├── AndroidManifest.xml
        ├── assets/                      # test.mscz lands here (gitignored)
        ├── jniLibs/                     # .so files (gitignored)
        ├── res/values/{strings.xml, themes.xml}
        └── java/com/example/sheetmusic/
            ├── MainActivity.kt
            ├── SheetMusicApp.kt
            ├── ScoreViewModel.kt
            ├── ScoreState.kt
            ├── ScoreView.kt
            ├── ScoreCanvas.kt
            ├── PageControls.kt
            ├── ui/theme/{Theme.kt, Color.kt, Type.kt}
            ├── draw/DrawProgramDecoder.kt
            └── jni/
                ├── SheetMusicBridge.kt
                └── ScoreHandle.kt
```

**Modified files:**

- `Package.swift` — add CJNI + SheetMusicAndroidJNI targets, add JNI product (Android-only), wire test deps.
- `CLAUDE.md` — extend Android build section, add Things-not-to-do bullet.
- `.gitignore` — none at repo root (all ignores are inside `Examples/Android/.gitignore`).

**Memory updates (after merge, not in this plan):**

- `project_android_port_roadmap` — Phase 4 status.
- `project_android_compose_example` (new) — JNI layout, draw-program rationale.

---

## Verification commands referenced repeatedly

```bash
# Apple host (no env)
swift build
swift test

# Android cross-compile, arm64
SWIFT_SHEET_MUSIC_ANDROID=1 TOOLCHAINS=org.swift.632202605101a \
    swift build --swift-sdk aarch64-unknown-linux-android28

# Android cross-compile, x86_64
SWIFT_SHEET_MUSIC_ANDROID=1 TOOLCHAINS=org.swift.632202605101a \
    swift build --swift-sdk x86_64-unknown-linux-android28

# Package shape check (both must succeed)
swift package describe --type json | jq '.targets | map(.name)' > /tmp/apple-targets.json
SWIFT_SHEET_MUSIC_ANDROID=1 swift package describe --type json | \
    jq '.targets | map(.name)' > /tmp/android-targets.json
```

---

### Task 1: Add CJNI module wrapper (Android-only)

**Files:**
- Create: `Sources/CJNI/module.modulemap`
- Create: `Sources/CJNI/shim.h`

- [ ] **Step 1: Create `Sources/CJNI/shim.h`**

```c
#ifndef SHEET_MUSIC_CJNI_SHIM_H
#define SHEET_MUSIC_CJNI_SHIM_H

#include <jni.h>

#endif
```

- [ ] **Step 2: Create `Sources/CJNI/module.modulemap`**

```
module CJNI {
    header "shim.h"
    export *
}
```

`jni.h` is found via the NDK sysroot include path that the Swift Android SDK already injects when building with `--swift-sdk <android-triple>`. On Apple host this module is never instantiated (see Task 2).

- [ ] **Step 3: Commit**

```bash
git add Sources/CJNI/module.modulemap Sources/CJNI/shim.h
git commit -m "feat(android-jni): add CJNI module wrapping <jni.h>"
```

---

### Task 2: Wire CJNI + SheetMusicAndroidJNI into Package.swift

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Write the failing check**

Run from repo root:

```bash
swift package describe --type json | jq -r '.targets[] | .name' | sort > /tmp/before-apple.txt
SWIFT_SHEET_MUSIC_ANDROID=1 swift package describe --type json | \
    jq -r '.targets[] | .name' | sort > /tmp/before-android.txt
cat /tmp/before-apple.txt
cat /tmp/before-android.txt
```

Expected: neither file contains `SheetMusicAndroidJNI` or `CJNI`.

- [ ] **Step 2: Edit `Package.swift`**

Three concrete changes:

**Change A —** Insert `SheetMusicAndroidJNI` into the always-present `targets` array. Find the `.target(name: "SheetMusicLayout", …)` entry; immediately after it (before the `.testTarget`), insert:

```swift
.target(
    name: "SheetMusicAndroidJNI",
    dependencies: [
        "SheetMusicCore",
        "SheetMusicMSCX",
        "SheetMusicMusicXML",
        "SheetMusicLayout",
    ] + (isAndroid ? ["CJNI"] : [])
),
```

**Change B —** Add `"SheetMusicAndroidJNI"` to BOTH branches of the test target's `dependencies:` array (the `isAndroid ? […] : […]` ternary).

**Change C —** Add a new `if isAndroid { … }` block right after the existing `if !isAndroid { … }` block, near the bottom of the file:

```swift
if isAndroid {
    products += [
        .library(name: "SheetMusicJNI",
                 type: .dynamic,
                 targets: ["SheetMusicAndroidJNI"]),
    ]
    targets += [
        .target(name: "CJNI",
                path: "Sources/CJNI",
                publicHeadersPath: "."),
    ]
}
```

- [ ] **Step 3: Create stub Swift file so target compiles**

```bash
mkdir -p Sources/SheetMusicAndroidJNI
cat > Sources/SheetMusicAndroidJNI/_Placeholder.swift <<'EOF'
// Temporary placeholder so SwiftPM accepts the target before real
// sources land in Task 3. Removed at end of Task 3.
internal enum SheetMusicAndroidJNIPlaceholder {}
EOF
```

- [ ] **Step 4: Verify both manifest shapes resolve**

```bash
swift package describe --type json | jq -r '.targets[] | .name' | sort | grep -E "SheetMusicAndroidJNI|CJNI"
```
Expected: only `SheetMusicAndroidJNI` (CJNI is Android-only).

```bash
SWIFT_SHEET_MUSIC_ANDROID=1 swift package describe --type json | \
    jq -r '.targets[] | .name' | sort | grep -E "SheetMusicAndroidJNI|CJNI"
```
Expected: both `CJNI` and `SheetMusicAndroidJNI` present.

- [ ] **Step 5: Verify Apple build is green**

```bash
swift build
swift test 2>&1 | tail -20
```
Expected: build succeeds; tests still 100% green.

- [ ] **Step 6: Verify Android cross-compile is green**

```bash
SWIFT_SHEET_MUSIC_ANDROID=1 TOOLCHAINS=org.swift.632202605101a \
    swift build --swift-sdk aarch64-unknown-linux-android28
```
Expected: build succeeds.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/SheetMusicAndroidJNI/_Placeholder.swift
git commit -m "feat(android-jni): add SheetMusicAndroidJNI target + SheetMusicJNI .so product"
```

---

### Task 3: Define draw-program binary format

**Files:**
- Create: `Sources/SheetMusicAndroidJNI/DrawProgram.swift`
- Delete: `Sources/SheetMusicAndroidJNI/_Placeholder.swift`

- [ ] **Step 1: Write `DrawProgram.swift`**

```swift
import Foundation

/// Self-describing binary format that ferries layout output across the JNI
/// boundary. Little-endian throughout. Both the Swift encoder and the Kotlin
/// decoder must agree on the magic + version; mismatches are fail-fast.
public enum DrawProgram {
    public static let magic: UInt32 = 0x53_4D_44_50    // "SMDP"
    public static let version: UInt32 = 1

    public enum Opcode: UInt8 {
        case moveTo   = 0x01
        case lineTo   = 0x02
        case stroke   = 0x03
        case fillRect = 0x04
        case glyph    = 0x05
        case text     = 0x06
    }

    public enum FontID: UInt8 {
        case textRoman = 0x00     // body text (Edwin / system serif)
        case smufl     = 0x01     // music glyphs (Bravura / Edwin SMuFL)
    }
}

/// Minimal LE byte sink. No throws on append; capacity grows naturally.
public struct BinaryWriter {
    public private(set) var data = Data()

    public init() {}

    public mutating func append<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
    }

    public mutating func append(_ value: Double) {
        append(value.bitPattern)
    }

    public mutating func append(utf8 string: String) {
        let bytes = Array(string.utf8)
        precondition(bytes.count <= Int(UInt16.max),
                     "draw-program text payload exceeds 65535 bytes")
        append(UInt16(bytes.count))
        data.append(contentsOf: bytes)
    }
}

/// Pull-style LE byte reader. Used only by Swift-side tests (the production
/// decoder is the Kotlin DrawProgramDecoder).
public struct BinaryReader {
    public let data: Data
    public private(set) var offset: Int

    public init(_ data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    public mutating func read<T: FixedWidthInteger>(_ type: T.Type) -> T {
        let size = MemoryLayout<T>.size
        precondition(offset + size <= data.count, "draw-program read overflow")
        var value: T = 0
        withUnsafeMutableBytes(of: &value) { dest in
            data.copyBytes(to: dest, from: offset..<(offset + size))
        }
        offset += size
        return T(littleEndian: value)
    }

    public mutating func readDouble() -> Double {
        Double(bitPattern: read(UInt64.self))
    }

    public mutating func readUTF8() -> String {
        let len = Int(read(UInt16.self))
        precondition(offset + len <= data.count, "draw-program string overflow")
        let bytes = data.subdata(in: offset..<(offset + len))
        offset += len
        return String(decoding: bytes, as: UTF8.self)
    }
}
```

- [ ] **Step 2: Remove placeholder**

```bash
rm Sources/SheetMusicAndroidJNI/_Placeholder.swift
```

- [ ] **Step 3: Verify build**

```bash
swift build
```
Expected: success.

- [ ] **Step 4: Commit**

```bash
git add Sources/SheetMusicAndroidJNI/DrawProgram.swift
git rm Sources/SheetMusicAndroidJNI/_Placeholder.swift
git commit -m "feat(android-jni): define draw-program binary format + LE codec helpers"
```

---

### Task 4: DrawProgramEncoder — `LayoutDocument` → `Data`

**Files:**
- Create: `Sources/SheetMusicAndroidJNI/DrawProgramEncoder.swift`
- Create: `Sources/SheetMusicAndroidJNI/DrawProgramDecoder.swift` (Swift-side, test-only)
- Create: `Tests/SheetMusicTests/AndroidJNI/DrawProgramRoundTripTests.swift`

> **Plan note:** This task encodes the subset of `LayoutDocument` needed for the first verification pass: page boundaries, staff lines (LINE_TO sequences), barlines (LINE_TO), and glyphs (notes, clefs, rests via GLYPH opcode). Slurs / ties / beams / hairpins are out of scope here — the spec deferred any opcodes beyond the listed six. If `LayoutDocument` exposes the relevant fields under different names than assumed here, the implementer must adapt: the spec's "Open questions" calls out that the page-size / glyph-API surface needs confirmation. Re-read `Sources/SheetMusicLayout/` before writing the encoder.

- [ ] **Step 1: Inspect `LayoutDocument` API surface**

```bash
ls Sources/SheetMusicLayout
grep -l "public struct LayoutDocument\|public struct LayoutPage" Sources/SheetMusicLayout -r
```

Read the structs/enums for: `LayoutDocument`, `LayoutPage`, anything carrying staff lines, barlines, glyphs. Note exact property names and units (mm / pt / spatium).

- [ ] **Step 2: Write the failing round-trip test**

Create `Tests/SheetMusicTests/AndroidJNI/DrawProgramRoundTripTests.swift`:

```swift
import Foundation
import Testing
@testable import SheetMusicAndroidJNI

@Suite
struct DrawProgramRoundTripTests {

    @Test
    func emptyDocumentRoundTrips() throws {
        let encoded = DrawProgramEncoder.encode(pages: [])
        var reader = BinaryReader(encoded)

        #expect(reader.read(UInt32.self) == DrawProgram.magic)
        #expect(reader.read(UInt32.self) == DrawProgram.version)
        #expect(reader.read(UInt32.self) == 0)   // pageCount
    }

    @Test
    func singlePageWithLineAndGlyphRoundTrips() throws {
        let page = EncodablePage(
            widthMM: 210, heightMM: 297,
            commands: [
                .moveTo(x: 20, y: 40),
                .lineTo(x: 190, y: 40),
                .stroke(width: 0.5),
                .glyph(codepoint: 0xE050, x: 30, y: 60,
                       size: 24, fontId: .smufl),  // gClef
            ]
        )
        let encoded = DrawProgramEncoder.encode(pages: [page])
        let decoded = try DrawProgramDecoder.decode(encoded)

        #expect(decoded.count == 1)
        #expect(decoded[0].widthMM == 210)
        #expect(decoded[0].heightMM == 297)
        #expect(decoded[0].commands.count == 4)
        if case let .glyph(codepoint, x, y, size, fontId) = decoded[0].commands[3] {
            #expect(codepoint == 0xE050)
            #expect(x == 30); #expect(y == 60); #expect(size == 24)
            #expect(fontId == .smufl)
        } else {
            Issue.record("expected glyph opcode at index 3")
        }
    }
}
```

Add the new test file to the test target — already covered by `resources: [.process("Resources")]` + glob; verify with `swift package describe --type json | jq '.targets[] | select(.name=="SheetMusicTests") | .sources' | grep DrawProgramRoundTrip`. If not listed, ensure no exclude rule filters the `AndroidJNI/` subfolder (SwiftPM picks `**/*.swift` by default).

- [ ] **Step 3: Run the failing test**

```bash
swift test --filter DrawProgramRoundTripTests
```
Expected: compile error — `DrawProgramEncoder`, `EncodablePage`, `DrawProgramDecoder` undefined.

- [ ] **Step 4: Implement encoder API + types**

Create `Sources/SheetMusicAndroidJNI/DrawProgramEncoder.swift`:

```swift
import Foundation
import SheetMusicCore
import SheetMusicLayout

/// Test-friendly mirror of one page's draw program. The production encoder
/// path consumes `LayoutDocument` directly via the `encode(layout:)` overload.
public struct EncodablePage: Sendable {
    public var widthMM: Double
    public var heightMM: Double
    public var commands: [DrawCommand]

    public init(widthMM: Double, heightMM: Double, commands: [DrawCommand]) {
        self.widthMM = widthMM
        self.heightMM = heightMM
        self.commands = commands
    }
}

public enum DrawCommand: Sendable, Equatable {
    case moveTo(x: Double, y: Double)
    case lineTo(x: Double, y: Double)
    case stroke(width: Double)
    case fillRect(x: Double, y: Double, w: Double, h: Double)
    case glyph(codepoint: UInt32, x: Double, y: Double,
               size: Double, fontId: DrawProgram.FontID)
    case text(String, x: Double, y: Double,
              size: Double, fontId: DrawProgram.FontID)
}

public enum DrawProgramEncoder {

    public static func encode(pages: [EncodablePage]) -> Data {
        var w = BinaryWriter()
        w.append(DrawProgram.magic)
        w.append(DrawProgram.version)
        w.append(UInt32(pages.count))
        for page in pages {
            encodePage(page, into: &w)
        }
        return w.data
    }

    /// Production entry point. Maps a `LayoutDocument` into draw commands.
    /// Implementer: fill this in after confirming `LayoutDocument`'s public
    /// surface. Until then, `encode(pages:)` is the unit-testable seam.
    public static func encode(layout: LayoutDocument) -> Data {
        let pages = layout.pages.map { page in
            EncodablePage(
                widthMM: page.size.width,
                heightMM: page.size.height,
                commands: commands(for: page)
            )
        }
        return encode(pages: pages)
    }

    private static func commands(for page: LayoutPage) -> [DrawCommand] {
        var out: [DrawCommand] = []
        // Staff lines.
        for staff in page.staves {
            for line in staff.lines {
                out.append(.moveTo(x: line.start.x, y: line.start.y))
                out.append(.lineTo(x: line.end.x, y: line.end.y))
                out.append(.stroke(width: line.thickness))
            }
        }
        // Glyphs.
        for glyph in page.glyphs {
            out.append(.glyph(
                codepoint: glyph.codepoint,
                x: glyph.position.x,
                y: glyph.position.y,
                size: glyph.size,
                fontId: glyph.isSMuFL ? .smufl : .textRoman
            ))
        }
        return out
    }

    private static func encodePage(_ page: EncodablePage,
                                   into w: inout BinaryWriter) {
        w.append(page.widthMM)
        w.append(page.heightMM)
        w.append(UInt32(page.commands.count))
        for cmd in page.commands {
            encodeCommand(cmd, into: &w)
        }
    }

    private static func encodeCommand(_ cmd: DrawCommand,
                                      into w: inout BinaryWriter) {
        switch cmd {
        case let .moveTo(x, y):
            w.append(DrawProgram.Opcode.moveTo.rawValue)
            w.append(x); w.append(y)
        case let .lineTo(x, y):
            w.append(DrawProgram.Opcode.lineTo.rawValue)
            w.append(x); w.append(y)
        case let .stroke(width):
            w.append(DrawProgram.Opcode.stroke.rawValue)
            w.append(width)
        case let .fillRect(x, y, ww, h):
            w.append(DrawProgram.Opcode.fillRect.rawValue)
            w.append(x); w.append(y); w.append(ww); w.append(h)
        case let .glyph(cp, x, y, size, fontId):
            w.append(DrawProgram.Opcode.glyph.rawValue)
            w.append(cp); w.append(x); w.append(y); w.append(size)
            w.append(fontId.rawValue)
        case let .text(s, x, y, size, fontId):
            w.append(DrawProgram.Opcode.text.rawValue)
            w.append(utf8: s)
            w.append(x); w.append(y); w.append(size)
            w.append(fontId.rawValue)
        }
    }
}
```

> **Plan note for implementer:** the `commands(for:)` body references `page.staves`, `staff.lines`, `page.glyphs`, `glyph.codepoint`, `glyph.isSMuFL`. If the actual `LayoutDocument` surface differs, adapt the code to its real shape; do not invent new public API in `SheetMusicLayout`. If the surface is too thin to express staves / glyphs, treat that as a discovered blocker: stop and report rather than guessing. (Per memory `feedback_subagent_no_unilateral_pivot`.)

Create `Sources/SheetMusicAndroidJNI/DrawProgramDecoder.swift`:

```swift
import Foundation

/// Swift-side decoder — testing only. The shipping decoder is the Kotlin
/// `DrawProgramDecoder` in Examples/Android/. Both must agree on the format
/// defined in DrawProgram.swift; keep them in lockstep.
public enum DrawProgramDecoder {

    public enum DecodeError: Error, Equatable {
        case badMagic(UInt32)
        case unsupportedVersion(UInt32)
        case unknownOpcode(UInt8)
    }

    public static func decode(_ data: Data) throws -> [EncodablePage] {
        var r = BinaryReader(data)
        let magic = r.read(UInt32.self)
        guard magic == DrawProgram.magic else {
            throw DecodeError.badMagic(magic)
        }
        let version = r.read(UInt32.self)
        guard version == DrawProgram.version else {
            throw DecodeError.unsupportedVersion(version)
        }
        let pageCount = Int(r.read(UInt32.self))
        var pages: [EncodablePage] = []
        pages.reserveCapacity(pageCount)
        for _ in 0..<pageCount {
            pages.append(try decodePage(&r))
        }
        return pages
    }

    private static func decodePage(_ r: inout BinaryReader) throws -> EncodablePage {
        let w = r.readDouble()
        let h = r.readDouble()
        let count = Int(r.read(UInt32.self))
        var commands: [DrawCommand] = []
        commands.reserveCapacity(count)
        for _ in 0..<count {
            commands.append(try decodeCommand(&r))
        }
        return EncodablePage(widthMM: w, heightMM: h, commands: commands)
    }

    private static func decodeCommand(_ r: inout BinaryReader) throws -> DrawCommand {
        let opByte = r.read(UInt8.self)
        guard let op = DrawProgram.Opcode(rawValue: opByte) else {
            throw DecodeError.unknownOpcode(opByte)
        }
        switch op {
        case .moveTo:   return .moveTo(x: r.readDouble(), y: r.readDouble())
        case .lineTo:   return .lineTo(x: r.readDouble(), y: r.readDouble())
        case .stroke:   return .stroke(width: r.readDouble())
        case .fillRect:
            return .fillRect(x: r.readDouble(), y: r.readDouble(),
                             w: r.readDouble(), h: r.readDouble())
        case .glyph:
            let cp = r.read(UInt32.self)
            let x = r.readDouble(); let y = r.readDouble()
            let size = r.readDouble()
            let fontId = DrawProgram.FontID(rawValue: r.read(UInt8.self)) ?? .textRoman
            return .glyph(codepoint: cp, x: x, y: y, size: size, fontId: fontId)
        case .text:
            let s = r.readUTF8()
            let x = r.readDouble(); let y = r.readDouble()
            let size = r.readDouble()
            let fontId = DrawProgram.FontID(rawValue: r.read(UInt8.self)) ?? .textRoman
            return .text(s, x: x, y: y, size: size, fontId: fontId)
        }
    }
}
```

- [ ] **Step 5: Run the tests**

```bash
swift test --filter DrawProgramRoundTripTests
```
Expected: both tests pass.

- [ ] **Step 6: Add an error-path test**

Append to `DrawProgramRoundTripTests.swift`:

```swift
    @Test
    func corruptMagicRaisesBadMagic() {
        var bytes = DrawProgramEncoder.encode(pages: [])
        bytes[0] = 0xFF
        #expect(throws: DrawProgramDecoder.DecodeError.self) {
            _ = try DrawProgramDecoder.decode(bytes)
        }
    }

    @Test
    func wrongVersionRaisesUnsupportedVersion() {
        var bytes = DrawProgramEncoder.encode(pages: [])
        bytes[4] = 0xFF       // bump version
        #expect(throws: DrawProgramDecoder.DecodeError.self) {
            _ = try DrawProgramDecoder.decode(bytes)
        }
    }
```

Run:
```bash
swift test --filter DrawProgramRoundTripTests
```
Expected: all four tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/SheetMusicAndroidJNI/DrawProgramEncoder.swift \
        Sources/SheetMusicAndroidJNI/DrawProgramDecoder.swift \
        Tests/SheetMusicTests/AndroidJNI/DrawProgramRoundTripTests.swift
git commit -m "feat(android-jni): DrawProgram encoder + Swift round-trip decoder"
```

---

### Task 5: HandleTable — thread-safe handle storage

**Files:**
- Create: `Sources/SheetMusicAndroidJNI/HandleTable.swift`
- Create: `Tests/SheetMusicTests/AndroidJNI/HandleTableTests.swift`

> **Design note:** JNI callbacks run on arbitrary Java threads. Using an `actor` forces async hops on every call from `JNISymbols.swift`, which is awkward in a `@_cdecl` context (no async). Instead, use a `DispatchQueue`-guarded dictionary with synchronous `sync` access. Per the spec's open question, this is the chosen tradeoff.

- [ ] **Step 1: Write the failing test**

`Tests/SheetMusicTests/AndroidJNI/HandleTableTests.swift`:

```swift
import Testing
@testable import SheetMusicAndroidJNI

@Suite
struct HandleTableTests {

    @Test
    func storeReturnsNonZeroHandle() {
        let table = HandleTable<String>()
        let h = table.insert("hello")
        #expect(h != 0)
    }

    @Test
    func storedValueRoundTrips() {
        let table = HandleTable<String>()
        let h = table.insert("hello")
        #expect(table.value(for: h) == "hello")
    }

    @Test
    func releaseRemovesValue() {
        let table = HandleTable<String>()
        let h = table.insert("hello")
        table.release(h)
        #expect(table.value(for: h) == nil)
    }

    @Test
    func handlesAreMonotonicAndUnique() {
        let table = HandleTable<Int>()
        let a = table.insert(1)
        let b = table.insert(2)
        let c = table.insert(3)
        #expect(a < b && b < c)
        #expect(Set([a, b, c]).count == 3)
    }

    @Test
    func releaseOfUnknownHandleIsNoOp() {
        let table = HandleTable<Int>()
        table.release(999)   // does not crash
        #expect(table.value(for: 999) == nil)
    }
}
```

Run:
```bash
swift test --filter HandleTableTests
```
Expected: compile error — `HandleTable` undefined.

- [ ] **Step 2: Implement `HandleTable`**

```swift
import Foundation

/// Maps opaque `Int64` handles to retained Swift objects. Thread-safe via
/// a serial dispatch queue. Handle `0` is reserved to mean "invalid / not
/// found" — JNI callers use it as the failure sentinel for `nativeLoadScore`.
public final class HandleTable<Value>: @unchecked Sendable {
    private let queue = DispatchQueue(label: "SheetMusicAndroidJNI.HandleTable")
    private var nextHandle: Int64 = 1
    private var storage: [Int64: Value] = [:]

    public init() {}

    public func insert(_ value: Value) -> Int64 {
        queue.sync {
            let h = nextHandle
            nextHandle += 1
            storage[h] = value
            return h
        }
    }

    public func value(for handle: Int64) -> Value? {
        queue.sync { storage[handle] }
    }

    public func release(_ handle: Int64) {
        queue.sync { _ = storage.removeValue(forKey: handle) }
    }
}
```

- [ ] **Step 3: Run tests**

```bash
swift test --filter HandleTableTests
```
Expected: all 5 tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/SheetMusicAndroidJNI/HandleTable.swift \
        Tests/SheetMusicTests/AndroidJNI/HandleTableTests.swift
git commit -m "feat(android-jni): HandleTable for thread-safe handle storage"
```

---

### Task 6: ScoreBridge — bytes → Score

**Files:**
- Create: `Sources/SheetMusicAndroidJNI/ScoreBridge.swift`
- Create: `Tests/SheetMusicTests/AndroidJNI/ScoreBridgeTests.swift`

- [ ] **Step 1: Write the failing test**

Pick an existing fixture from `Tests/SheetMusicTests/Resources/` — a small `.mscz` (e.g., `midi01.mscz` if present, or one of the GPL test fixtures already used by `MidiExportTests`). These fixtures are GPL-3.0 and stay confined to the test target — fine for this test, NOT fine for the shipped example app (CLAUDE.md "Things not to do").

```swift
import Foundation
import Testing
@testable import SheetMusicAndroidJNI

@Suite
struct ScoreBridgeTests {

    @Test
    func loadFromMSCXBytesProducesScore() throws {
        let url = Bundle.module.url(forResource: "midi01",
                                    withExtension: "mscx")!
        let bytes = try Data(contentsOf: url)
        let score = try ScoreBridge.loadScore(bytes: bytes)
        #expect(!score.parts.isEmpty)
    }

    @Test
    func loadFromMSCZBytesProducesScore() throws {
        let url = Bundle.module.url(forResource: "midi01",
                                    withExtension: "mscz")!
        let bytes = try Data(contentsOf: url)
        let score = try ScoreBridge.loadScore(bytes: bytes)
        #expect(!score.parts.isEmpty)
    }

    @Test
    func loadFromGarbageThrows() {
        #expect(throws: Error.self) {
            _ = try ScoreBridge.loadScore(bytes: Data("not a score".utf8))
        }
    }
}
```

If `midi01.mscz` is not present in `Tests/SheetMusicTests/Resources/`, swap the resource name for any fixture verifiable via `ls Tests/SheetMusicTests/Resources/*.mscz`.

Run:
```bash
swift test --filter ScoreBridgeTests
```
Expected: compile error — `ScoreBridge` undefined.

- [ ] **Step 2: Implement ScoreBridge**

```swift
import Foundation
import SheetMusicCore
import SheetMusicMSCX
import SheetMusicMusicXML

/// Routes a raw byte payload (`.mscx`, `.mscz`, `.musicxml`, `.mxl`) to the
/// matching parser by sniffing the first few bytes. Returns the parsed Score
/// or throws SheetMusicError.
public enum ScoreBridge {

    public enum SniffedFormat {
        case mscx, mscz, musicXML, mxl, unknown
    }

    public static func sniff(_ bytes: Data) -> SniffedFormat {
        // ZIP (PK\x03\x04) — mscz or mxl. Distinguish by inner file.
        if bytes.count >= 4,
           bytes[0] == 0x50, bytes[1] == 0x4B,
           bytes[2] == 0x03, bytes[3] == 0x04 {
            // The container distinction (mscz vs mxl) is left to the
            // respective decoders; try mscz first since it's the
            // common case for this example.
            return .mscz
        }
        // XML (with or without BOM). Distinguish mscx vs musicXML by
        // root element name appearing in the first 256 bytes.
        let prefix = bytes.prefix(256)
        if let text = String(data: prefix, encoding: .utf8) {
            if text.contains("<museScore") { return .mscx }
            if text.contains("<score-partwise") || text.contains("<score-timewise") {
                return .musicXML
            }
        }
        return .unknown
    }

    public static func loadScore(bytes: Data) throws -> Score {
        switch sniff(bytes) {
        case .mscx:
            return try MSCXParser.parse(data: bytes)
        case .mscz:
            // mscz container: try MSCXParser first; if it rejects, try mxl.
            do {
                return try MSCXParser.parse(data: bytes)
            } catch {
                return try MusicXMLParser.parse(data: bytes)
            }
        case .musicXML:
            return try MusicXMLParser.parse(data: bytes)
        case .mxl:
            return try MusicXMLParser.parse(data: bytes)
        case .unknown:
            throw SheetMusicError.malformedScore(
                "unrecognized score format (not mscx/mscz/musicxml/mxl)"
            )
        }
    }
}
```

> **Plan note:** the exact `MSCXParser.parse` / `MusicXMLParser.parse` signatures may differ. Inspect `Sources/SheetMusicMSCX/MSCXParser.swift` and `Sources/SheetMusicMusicXML/MusicXMLParser.swift` and adapt: `parse(data:)`, `parse(_:)`, `parseScore(from:)` — use whichever exists. If both parsers require a `URL`, write a temporary-file shim inside `loadScore`. Do not invent new public API.

- [ ] **Step 3: Run tests**

```bash
swift test --filter ScoreBridgeTests
```
Expected: all 3 tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/SheetMusicAndroidJNI/ScoreBridge.swift \
        Tests/SheetMusicTests/AndroidJNI/ScoreBridgeTests.swift
git commit -m "feat(android-jni): ScoreBridge sniffs format + parses bytes → Score"
```

---

### Task 7: LayoutBridge — Score + page size → draw-program bytes

**Files:**
- Create: `Sources/SheetMusicAndroidJNI/LayoutBridge.swift`
- Create: `Tests/SheetMusicTests/AndroidJNI/LayoutBridgeTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import SheetMusicAndroidJNI

@Suite
struct LayoutBridgeTests {

    @Test
    func emptyScoreProducesAtLeastOnePage() throws {
        let url = Bundle.module.url(forResource: "midi01",
                                    withExtension: "mscx")!
        let bytes = try Data(contentsOf: url)
        let score = try ScoreBridge.loadScore(bytes: bytes)
        let encoded = LayoutBridge.compute(score: score,
                                           pageWidthMM: 210,
                                           pageHeightMM: 297)
        let pages = try DrawProgramDecoder.decode(encoded)
        #expect(!pages.isEmpty)
    }

    @Test
    func headerMagicAndVersionAreCorrect() throws {
        let url = Bundle.module.url(forResource: "midi01",
                                    withExtension: "mscx")!
        let bytes = try Data(contentsOf: url)
        let score = try ScoreBridge.loadScore(bytes: bytes)
        let encoded = LayoutBridge.compute(score: score,
                                           pageWidthMM: 210,
                                           pageHeightMM: 297)
        var r = BinaryReader(encoded)
        #expect(r.read(UInt32.self) == DrawProgram.magic)
        #expect(r.read(UInt32.self) == DrawProgram.version)
    }
}
```

Run:
```bash
swift test --filter LayoutBridgeTests
```
Expected: compile error — `LayoutBridge` undefined.

- [ ] **Step 2: Implement LayoutBridge**

```swift
import Foundation
import SheetMusicCore
import SheetMusicLayout

/// Runs the cross-platform layout engine and serializes the result.
public enum LayoutBridge {

    public static func compute(score: Score,
                               pageWidthMM: Double,
                               pageHeightMM: Double) -> Data {
        // Phase 2 left `LayoutDocument(score:fontMetrics:pageSize:)`-style
        // initializers on SheetMusicLayout. Use whichever constructor /
        // builder is publicly exposed; on Android `StubFontMetricsProvider`
        // is auto-installed when no Apple-side provider is available.
        let metrics = StubFontMetricsProvider()
        let document = LayoutDocument(
            score: score,
            fontMetrics: metrics,
            pageSize: .init(width: pageWidthMM, height: pageHeightMM)
        )
        return DrawProgramEncoder.encode(layout: document)
    }
}
```

> **Plan note:** confirm `LayoutDocument` initializer signature in `Sources/SheetMusicLayout/`. If the actual constructor is `LayoutDocument.compute(score:)`, adapt. The unit on `pageSize` should match Phase 2's choice — confirm before guessing.

- [ ] **Step 3: Run tests**

```bash
swift test --filter LayoutBridgeTests
```
Expected: both tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/SheetMusicAndroidJNI/LayoutBridge.swift \
        Tests/SheetMusicTests/AndroidJNI/LayoutBridgeTests.swift
git commit -m "feat(android-jni): LayoutBridge — score + page size → draw-program bytes"
```

---

### Task 8: `@_cdecl` JNI entry points (Android-only)

**Files:**
- Create: `Sources/SheetMusicAndroidJNI/JNISymbols.swift`

This task has no Apple unit tests — `@_cdecl` symbol generation and JNIEnv access are only meaningful in a cross-compiled binary. Verification is via successful Android cross-compile.

- [ ] **Step 1: Write `JNISymbols.swift`**

```swift
#if os(Android)
import Foundation
import CJNI
import SheetMusicCore
import SheetMusicLayout

/// Singleton tables — one per Swift type. Lifetimes are explicit; Kotlin
/// must release every handle it gets, or the score will leak until process
/// exit.
private let scoreTable = HandleTable<Score>()

// MARK: - Score lifecycle

@_cdecl("Java_com_example_sheetmusic_jni_SheetMusicBridge_nativeLoadScore")
public func Java_com_example_sheetmusic_jni_SheetMusicBridge_nativeLoadScore(
    _ envPtr: UnsafeMutablePointer<JNIEnv?>,
    _ clazz: jclass,
    _ byteArray: jbyteArray
) -> jlong {
    guard let env = envPtr.pointee else { return 0 }
    let len = env.pointee.GetArrayLength(envPtr, byteArray)
    guard len > 0 else { return 0 }
    var bytes = [UInt8](repeating: 0, count: Int(len))
    bytes.withUnsafeMutableBufferPointer { buf in
        env.pointee.GetByteArrayRegion(envPtr, byteArray, 0, len,
                                       buf.baseAddress!
                                          .withMemoryRebound(to: jbyte.self,
                                                             capacity: Int(len)) { $0 })
    }
    let data = Data(bytes)
    do {
        let score = try ScoreBridge.loadScore(bytes: data)
        return scoreTable.insert(score)
    } catch {
        return 0
    }
}

@_cdecl("Java_com_example_sheetmusic_jni_SheetMusicBridge_nativeReleaseScore")
public func Java_com_example_sheetmusic_jni_SheetMusicBridge_nativeReleaseScore(
    _ envPtr: UnsafeMutablePointer<JNIEnv?>,
    _ clazz: jclass,
    _ handle: jlong
) {
    scoreTable.release(handle)
}

// MARK: - Layout

@_cdecl("Java_com_example_sheetmusic_jni_SheetMusicBridge_nativeComputeLayout")
public func Java_com_example_sheetmusic_jni_SheetMusicBridge_nativeComputeLayout(
    _ envPtr: UnsafeMutablePointer<JNIEnv?>,
    _ clazz: jclass,
    _ scoreHandle: jlong,
    _ pageWidthMM: jdouble,
    _ pageHeightMM: jdouble
) -> jbyteArray? {
    guard let env = envPtr.pointee else { return nil }
    guard let score = scoreTable.value(for: scoreHandle) else {
        return env.pointee.NewByteArray(envPtr, 0)
    }
    let encoded = LayoutBridge.compute(score: score,
                                       pageWidthMM: pageWidthMM,
                                       pageHeightMM: pageHeightMM)
    let array = env.pointee.NewByteArray(envPtr, jsize(encoded.count))
    encoded.withUnsafeBytes { rawBuf in
        let typed = rawBuf.bindMemory(to: jbyte.self)
        env.pointee.SetByteArrayRegion(envPtr, array, 0,
                                       jsize(encoded.count),
                                       typed.baseAddress)
    }
    return array
}
#endif
```

> **Implementer note:** The exact JNIEnv vtable access pattern differs slightly between NDK versions. If `env.pointee.GetArrayLength(envPtr, byteArray)` does not compile, try `env.pointee.pointee.GetArrayLength(envPtr, byteArray)` (the extra `.pointee` accounts for `JNINativeInterface_` being one level deeper). Both forms appear in published Swift-on-Android samples. Pick whichever compiles and stick with it consistently across all three symbols.

- [ ] **Step 2: Cross-compile for arm64**

```bash
SWIFT_SHEET_MUSIC_ANDROID=1 TOOLCHAINS=org.swift.632202605101a \
    swift build --swift-sdk aarch64-unknown-linux-android28 \
                --product SheetMusicJNI
```
Expected: success; `.build/aarch64-unknown-linux-android28/debug/libSheetMusicJNI.so` exists.

- [ ] **Step 3: Cross-compile for x86_64**

```bash
SWIFT_SHEET_MUSIC_ANDROID=1 TOOLCHAINS=org.swift.632202605101a \
    swift build --swift-sdk x86_64-unknown-linux-android28 \
                --product SheetMusicJNI
```
Expected: success.

- [ ] **Step 4: Verify exported JNI symbols**

```bash
nm -D --defined-only \
   .build/aarch64-unknown-linux-android28/debug/libSheetMusicJNI.so \
   2>/dev/null | grep -E "Java_com_example_sheetmusic"
```
Expected: three lines, one per `nativeLoadScore`, `nativeReleaseScore`, `nativeComputeLayout`. If `nm` is unavailable in this toolchain, use `objdump -T` or `${NDK}/toolchains/llvm/prebuilt/*/bin/llvm-nm`.

- [ ] **Step 5: Verify Apple build still green**

```bash
swift test 2>&1 | tail -10
```
Expected: 100% green (JNISymbols.swift contributes nothing on Apple).

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicAndroidJNI/JNISymbols.swift
git commit -m "feat(android-jni): @_cdecl JNI entry points for score lifecycle + layout"
```

---

### Task 9: `Scripts/android-build-libs.sh`

**Files:**
- Create: `Scripts/android-build-libs.sh`

- [ ] **Step 1: Author the script**

```bash
#!/usr/bin/env bash
# Build SheetMusicJNI for each enabled Android ABI and stage .so files
# (plus Swift runtime stubs) into Examples/Android/app/src/main/jniLibs/.
set -euo pipefail

: "${TOOLCHAINS:=org.swift.632202605101a}"
export TOOLCHAINS
export SWIFT_SHEET_MUSIC_ANDROID=1

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
JNI_DIR="$ROOT/Examples/Android/app/src/main/jniLibs"
SDK_BUNDLE="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3.2-RELEASE_android.artifactbundle"
RUNTIME_BASE="$SDK_BUNDLE/swift-android/sysroot/usr/lib"

declare -A ABI_DIR=(
    [aarch64-unknown-linux-android28]="arm64-v8a"
    [x86_64-unknown-linux-android28]="x86_64"
)
declare -A RUNTIME_ARCH=(
    [aarch64-unknown-linux-android28]="aarch64"
    [x86_64-unknown-linux-android28]="x86_64"
)

mkdir -p "$JNI_DIR"

for triple in "${!ABI_DIR[@]}"; do
    abi="${ABI_DIR[$triple]}"
    arch="${RUNTIME_ARCH[$triple]}"
    echo
    echo "==> Building libSheetMusicJNI.so for $abi ($triple)"
    swift build --package-path "$ROOT" \
                --product SheetMusicJNI \
                --swift-sdk "$triple" \
                -c release

    src_so="$ROOT/.build/$triple/release/libSheetMusicJNI.so"
    dst_dir="$JNI_DIR/$abi"
    mkdir -p "$dst_dir"
    cp "$src_so" "$dst_dir/"

    echo "==> Staging Swift runtime stubs into $dst_dir"
    runtime_src="$RUNTIME_BASE/$arch"
    if [[ ! -d "$runtime_src" ]]; then
        echo "error: Swift runtime not found at $runtime_src" >&2
        echo "      Re-derive the path from your installed Swift Android SDK." >&2
        exit 1
    fi
    for so in libswiftCore.so libswift_Concurrency.so libswiftAndroid.so \
              libFoundation.so libFoundationEssentials.so \
              libFoundationInternationalization.so libdispatch.so \
              libBlocksRuntime.so; do
        if [[ -f "$runtime_src/$so" ]]; then
            cp "$runtime_src/$so" "$dst_dir/"
        fi
    done
done

echo
echo "Done. libSheetMusicJNI.so + runtime staged under:"
echo "  $JNI_DIR/{arm64-v8a,x86_64}/"
echo
echo "Next: place ~/Desktop/test.mscz and run"
echo "      Scripts/android-bundle-test-score.sh"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x Scripts/android-build-libs.sh
```

- [ ] **Step 3: Run the script**

```bash
Scripts/android-build-libs.sh
```
Expected output: two builds succeed, `.so` files appear in
`Examples/Android/app/src/main/jniLibs/arm64-v8a/` and
`Examples/Android/app/src/main/jniLibs/x86_64/`. If the runtime path is wrong (changed in a future SDK bundle), the script fails loudly — re-derive from the actual SDK directory tree under `~/Library/org.swift.swiftpm/swift-sdks/`.

- [ ] **Step 4: Verify staged files**

```bash
ls Examples/Android/app/src/main/jniLibs/arm64-v8a/ | grep -E "SheetMusicJNI|swiftCore"
ls Examples/Android/app/src/main/jniLibs/x86_64/   | grep -E "SheetMusicJNI|swiftCore"
```
Expected: at least `libSheetMusicJNI.so` and `libswiftCore.so` in each directory.

- [ ] **Step 5: Commit**

```bash
git add Scripts/android-build-libs.sh
git commit -m "feat(android-jni): build script — cross-compile + stage .so per ABI"
```

---

### Task 10: `Scripts/android-bundle-test-score.sh`

**Files:**
- Create: `Scripts/android-bundle-test-score.sh`

- [ ] **Step 1: Author the script**

```bash
#!/usr/bin/env bash
# Copies a developer-supplied test.mscz from ~/Desktop into the Android
# example's assets directory. The destination is gitignored.
set -euo pipefail

SRC="$HOME/Desktop/test.mscz"
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
DST="$ROOT/Examples/Android/app/src/main/assets/test.mscz"

if [[ ! -f "$SRC" ]]; then
    echo "error: $SRC not found" >&2
    echo "      place a MuseScore file there (or a symlink) and rerun this script" >&2
    exit 1
fi

mkdir -p "$(dirname "$DST")"
cp "$SRC" "$DST"
echo "copied $SRC -> $DST"
```

- [ ] **Step 2: Make executable**

```bash
chmod +x Scripts/android-bundle-test-score.sh
```

- [ ] **Step 3: Verify happy path**

```bash
ls -la ~/Desktop/test.mscz   # confirm source present
Scripts/android-bundle-test-score.sh
ls -la Examples/Android/app/src/main/assets/test.mscz
```
Expected: copied file matches source size.

- [ ] **Step 4: Verify failure path**

```bash
mv ~/Desktop/test.mscz ~/Desktop/test.mscz.bak
Scripts/android-bundle-test-score.sh; echo "exit=$?"
mv ~/Desktop/test.mscz.bak ~/Desktop/test.mscz
```
Expected: script exits non-zero with the "place a MuseScore file" error.

- [ ] **Step 5: Commit**

```bash
git add Scripts/android-bundle-test-score.sh
git commit -m "feat(android-example): bundle script — copy ~/Desktop/test.mscz → assets"
```

---

### Task 11: Examples/Android — Gradle skeleton + AndroidManifest

**Files:**
- Create: `Examples/Android/.gitignore`
- Create: `Examples/Android/settings.gradle.kts`
- Create: `Examples/Android/build.gradle.kts`
- Create: `Examples/Android/gradle.properties`
- Create: `Examples/Android/gradle/wrapper/gradle-wrapper.properties`
- Create: `Examples/Android/gradlew`, `gradlew.bat` (via `gradle wrapper`)
- Create: `Examples/Android/app/build.gradle.kts`
- Create: `Examples/Android/app/proguard-rules.pro`
- Create: `Examples/Android/app/src/main/AndroidManifest.xml`
- Create: `Examples/Android/app/src/main/res/values/{strings.xml, themes.xml, colors.xml}`

- [ ] **Step 1: `Examples/Android/.gitignore`**

```
.gradle/
build/
app/build/
app/src/main/jniLibs/
app/src/main/assets/test.mscz
local.properties
.idea/
*.iml
captures/
```

- [ ] **Step 2: `Examples/Android/settings.gradle.kts`**

```kotlin
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}
rootProject.name = "SheetMusicAndroidExample"
include(":app")
```

- [ ] **Step 3: `Examples/Android/build.gradle.kts`**

```kotlin
plugins {
    id("com.android.application") version "8.5.0" apply false
    id("org.jetbrains.kotlin.android") version "2.0.20" apply false
    id("org.jetbrains.kotlin.plugin.compose") version "2.0.20" apply false
}
```

- [ ] **Step 4: `Examples/Android/gradle.properties`**

```
org.gradle.jvmargs=-Xmx4096m -Dfile.encoding=UTF-8
android.useAndroidX=true
kotlin.code.style=official
```

- [ ] **Step 5: Gradle wrapper**

From a shell with Gradle 8.5+ on PATH:

```bash
cd Examples/Android
gradle wrapper --gradle-version 8.7 --distribution-type bin
cd ../..
```

If Gradle isn't installed locally, instead create `Examples/Android/gradle/wrapper/gradle-wrapper.properties` manually:

```
distributionBase=GRADLE_USER_HOME
distributionPath=wrapper/dists
distributionUrl=https\://services.gradle.org/distributions/gradle-8.7-bin.zip
networkTimeout=10000
validateDistributionUrl=true
zipStoreBase=GRADLE_USER_HOME
zipStorePath=wrapper/dists
```

…and download `gradle-wrapper.jar` from the matching tag once on first build.

- [ ] **Step 6: `Examples/Android/app/build.gradle.kts`**

```kotlin
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "com.example.sheetmusic"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.example.sheetmusic"
        minSdk = 28
        targetSdk = 35
        versionCode = 1
        versionName = "0.1"
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }

    buildFeatures { compose = true }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }

    sourceSets["main"].jniLibs.srcDirs("src/main/jniLibs")
}

dependencies {
    val composeBom = platform("androidx.compose:compose-bom:2024.09.02")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.activity:activity-compose:1.9.2")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.6")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.6")
    debugImplementation("androidx.compose.ui:ui-tooling")
    testImplementation("junit:junit:4.13.2")
}
```

- [ ] **Step 7: `Examples/Android/app/proguard-rules.pro`**

```
-keep class com.example.sheetmusic.jni.** { *; }
```

- [ ] **Step 8: `Examples/Android/app/src/main/AndroidManifest.xml`**

```xml
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <application
        android:label="SheetMusic"
        android:theme="@style/Theme.SheetMusic"
        android:supportsRtl="true">

        <activity
            android:name=".MainActivity"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
```

- [ ] **Step 9: Resource stubs**

`Examples/Android/app/src/main/res/values/strings.xml`:
```xml
<resources>
    <string name="app_name">SheetMusic</string>
</resources>
```

`Examples/Android/app/src/main/res/values/themes.xml`:
```xml
<resources xmlns:tools="http://schemas.android.com/tools">
    <style name="Theme.SheetMusic" parent="android:Theme.Material.Light.NoActionBar"/>
</resources>
```

`Examples/Android/app/src/main/res/values/colors.xml`:
```xml
<resources>
    <color name="white">#FFFFFFFF</color>
    <color name="black">#FF000000</color>
</resources>
```

- [ ] **Step 10: Commit**

```bash
git add Examples/Android/.gitignore \
        Examples/Android/settings.gradle.kts \
        Examples/Android/build.gradle.kts \
        Examples/Android/gradle.properties \
        Examples/Android/gradle/wrapper/ \
        Examples/Android/gradlew Examples/Android/gradlew.bat \
        Examples/Android/app/build.gradle.kts \
        Examples/Android/app/proguard-rules.pro \
        Examples/Android/app/src/main/AndroidManifest.xml \
        Examples/Android/app/src/main/res/
git commit -m "feat(android-example): Gradle project skeleton (Compose + jniLibs wiring)"
```

---

### Task 12: Kotlin DrawProgramDecoder + unit test

**Files:**
- Create: `Examples/Android/app/src/main/java/com/example/sheetmusic/draw/DrawProgramDecoder.kt`
- Create: `Examples/Android/app/src/test/java/com/example/sheetmusic/draw/DrawProgramDecoderTest.kt`

- [ ] **Step 1: Add test source set to `app/build.gradle.kts`**

Already covered by AGP defaults (`src/test/java`). No edit needed unless test fails to discover.

- [ ] **Step 2: Write the failing test**

`Examples/Android/app/src/test/java/com/example/sheetmusic/draw/DrawProgramDecoderTest.kt`:

```kotlin
package com.example.sheetmusic.draw

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class DrawProgramDecoderTest {

    @Test
    fun emptyProgramHasZeroPages() {
        val bytes = ByteBuffer.allocate(12).order(ByteOrder.LITTLE_ENDIAN).apply {
            putInt(0x53_4D_44_50.toInt())   // magic "SMDP"
            putInt(1)                       // version
            putInt(0)                       // pageCount
        }.array()

        val program = DrawProgramDecoder.decode(bytes)

        assertEquals(0, program.pages.size)
    }

    @Test
    fun singlePageWithLineAndGlyphDecodes() {
        val bytes = buildProgram {
            page(widthMM = 210.0, heightMM = 297.0) {
                moveTo(20.0, 40.0)
                lineTo(190.0, 40.0)
                stroke(0.5)
                glyph(codepoint = 0xE050u, x = 30.0, y = 60.0,
                      size = 24.0, fontId = 1)
            }
        }

        val program = DrawProgramDecoder.decode(bytes)

        assertEquals(1, program.pages.size)
        val page = program.pages[0]
        assertEquals(210.0, page.widthMM, 0.0)
        assertEquals(297.0, page.heightMM, 0.0)
        assertEquals(4, page.commands.size)
        val glyph = page.commands[3] as DrawCommand.Glyph
        assertEquals(0xE050u, glyph.codepoint)
        assertEquals(30.0, glyph.x, 0.0)
        assertEquals(1, glyph.fontId)
    }

    @Test(expected = DrawProgramDecoder.BadMagicException::class)
    fun corruptMagicThrows() {
        val bytes = ByteBuffer.allocate(12).order(ByteOrder.LITTLE_ENDIAN).apply {
            putInt(0xCAFEBABE.toInt())
            putInt(1); putInt(0)
        }.array()
        DrawProgramDecoder.decode(bytes)
    }
}

/** Small fluent builder used only by this test. Mirrors the spec format. */
private fun buildProgram(block: ProgramBuilder.() -> Unit): ByteArray {
    val b = ProgramBuilder()
    b.block()
    return b.toBytes()
}

private class ProgramBuilder {
    private val pages = mutableListOf<PageBuilder>()
    fun page(widthMM: Double, heightMM: Double, block: PageBuilder.() -> Unit) {
        val p = PageBuilder(widthMM, heightMM)
        p.block(); pages.add(p)
    }
    fun toBytes(): ByteArray {
        var capacity = 12
        for (p in pages) capacity += p.byteSize
        val buf = ByteBuffer.allocate(capacity).order(ByteOrder.LITTLE_ENDIAN)
        buf.putInt(0x53_4D_44_50.toInt()); buf.putInt(1); buf.putInt(pages.size)
        for (p in pages) p.writeTo(buf)
        return buf.array()
    }
}

private class PageBuilder(val widthMM: Double, val heightMM: Double) {
    private val cmds = mutableListOf<ByteArray>()
    val byteSize: Int get() = 8 + 8 + 4 + cmds.sumOf { it.size }

    fun moveTo(x: Double, y: Double)   = emit { it.put(0x01); it.putDouble(x); it.putDouble(y) }
    fun lineTo(x: Double, y: Double)   = emit { it.put(0x02); it.putDouble(x); it.putDouble(y) }
    fun stroke(w: Double)              = emit { it.put(0x03); it.putDouble(w) }
    fun glyph(codepoint: UInt, x: Double, y: Double, size: Double, fontId: Int) =
        emit {
            it.put(0x05); it.putInt(codepoint.toInt())
            it.putDouble(x); it.putDouble(y); it.putDouble(size); it.put(fontId.toByte())
        }

    private fun emit(write: (ByteBuffer) -> Unit) {
        val tmp = ByteBuffer.allocate(64).order(ByteOrder.LITTLE_ENDIAN)
        write(tmp); tmp.flip()
        val arr = ByteArray(tmp.remaining()); tmp.get(arr); cmds.add(arr)
    }

    fun writeTo(buf: ByteBuffer) {
        buf.putDouble(widthMM); buf.putDouble(heightMM)
        buf.putInt(cmds.size)
        for (c in cmds) buf.put(c)
    }
}
```

Run from `Examples/Android/`:
```bash
./gradlew :app:testDebugUnitTest
```
Expected: compile error — `DrawProgramDecoder` undefined.

- [ ] **Step 3: Implement DrawProgramDecoder**

`Examples/Android/app/src/main/java/com/example/sheetmusic/draw/DrawProgramDecoder.kt`:

```kotlin
package com.example.sheetmusic.draw

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Decodes the little-endian draw-program byte stream produced by the
 * SheetMusicAndroidJNI Swift target. Format spec lives at
 * Sources/SheetMusicAndroidJNI/DrawProgram.swift — keep both sides in sync.
 */
object DrawProgramDecoder {

    private const val MAGIC = 0x53_4D_44_50   // "SMDP"
    private const val VERSION = 1

    class BadMagicException(actual: Int) :
        RuntimeException("bad draw-program magic: 0x${actual.toString(16)}")

    class UnsupportedVersionException(actual: Int) :
        RuntimeException("unsupported draw-program version: $actual")

    class UnknownOpcodeException(actual: Int) :
        RuntimeException("unknown opcode: 0x${actual.toString(16)}")

    fun decode(bytes: ByteArray): DrawProgram {
        val buf = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        val magic = buf.int
        if (magic != MAGIC) throw BadMagicException(magic)
        val version = buf.int
        if (version != VERSION) throw UnsupportedVersionException(version)
        val pageCount = buf.int
        val pages = ArrayList<DrawPage>(pageCount)
        repeat(pageCount) { pages.add(decodePage(buf)) }
        return DrawProgram(pages)
    }

    private fun decodePage(buf: ByteBuffer): DrawPage {
        val w = buf.double
        val h = buf.double
        val n = buf.int
        val cmds = ArrayList<DrawCommand>(n)
        repeat(n) { cmds.add(decodeCommand(buf)) }
        return DrawPage(w, h, cmds)
    }

    private fun decodeCommand(buf: ByteBuffer): DrawCommand =
        when (val op = buf.get().toInt() and 0xFF) {
            0x01 -> DrawCommand.MoveTo(buf.double, buf.double)
            0x02 -> DrawCommand.LineTo(buf.double, buf.double)
            0x03 -> DrawCommand.Stroke(buf.double)
            0x04 -> DrawCommand.FillRect(buf.double, buf.double,
                                         buf.double, buf.double)
            0x05 -> DrawCommand.Glyph(
                        codepoint = buf.int.toUInt(),
                        x = buf.double, y = buf.double,
                        size = buf.double,
                        fontId = buf.get().toInt() and 0xFF)
            0x06 -> {
                val len = buf.short.toInt() and 0xFFFF
                val bytes = ByteArray(len); buf.get(bytes)
                DrawCommand.Text(
                    text = String(bytes, Charsets.UTF_8),
                    x = buf.double, y = buf.double,
                    size = buf.double,
                    fontId = buf.get().toInt() and 0xFF)
            }
            else -> throw UnknownOpcodeException(op)
        }
}

data class DrawProgram(val pages: List<DrawPage>)
data class DrawPage(val widthMM: Double, val heightMM: Double,
                    val commands: List<DrawCommand>)

sealed interface DrawCommand {
    data class MoveTo(val x: Double, val y: Double) : DrawCommand
    data class LineTo(val x: Double, val y: Double) : DrawCommand
    data class Stroke(val width: Double) : DrawCommand
    data class FillRect(val x: Double, val y: Double,
                        val w: Double, val h: Double) : DrawCommand
    data class Glyph(val codepoint: UInt, val x: Double, val y: Double,
                     val size: Double, val fontId: Int) : DrawCommand
    data class Text(val text: String, val x: Double, val y: Double,
                    val size: Double, val fontId: Int) : DrawCommand
}
```

- [ ] **Step 4: Run tests**

```bash
cd Examples/Android && ./gradlew :app:testDebugUnitTest && cd ../..
```
Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Examples/Android/app/src/main/java/com/example/sheetmusic/draw/DrawProgramDecoder.kt \
        Examples/Android/app/src/test/java/com/example/sheetmusic/draw/DrawProgramDecoderTest.kt
git commit -m "feat(android-example): Kotlin DrawProgramDecoder + unit tests"
```

---

### Task 13: JNI bridge layer (Kotlin)

**Files:**
- Create: `Examples/Android/app/src/main/java/com/example/sheetmusic/jni/SheetMusicBridge.kt`
- Create: `Examples/Android/app/src/main/java/com/example/sheetmusic/jni/ScoreHandle.kt`

No unit tests — these require the .so to be loaded, which only happens on an Android device / emulator. Smoke-tested in Task 18.

- [ ] **Step 1: `SheetMusicBridge.kt`**

```kotlin
package com.example.sheetmusic.jni

/**
 * Thin façade over the @_cdecl symbols exported by
 * Sources/SheetMusicAndroidJNI/JNISymbols.swift. All methods are JNI;
 * keep symbol names in lockstep (com.example.sheetmusic.jni.SheetMusicBridge
 * maps to Java_com_example_sheetmusic_jni_SheetMusicBridge_<name>).
 */
object SheetMusicBridge {

    init { System.loadLibrary("SheetMusicJNI") }

    /** Returns 0 on parse failure. */
    @JvmStatic external fun nativeLoadScore(bytes: ByteArray): Long

    @JvmStatic external fun nativeReleaseScore(handle: Long)

    /** Returns an empty array on failure (e.g. invalid handle). */
    @JvmStatic external fun nativeComputeLayout(
        scoreHandle: Long,
        pageWidthMM: Double,
        pageHeightMM: Double,
    ): ByteArray
}
```

- [ ] **Step 2: `ScoreHandle.kt`**

```kotlin
package com.example.sheetmusic.jni

/** Auto-releasing wrapper around a native score handle. */
class ScoreHandle internal constructor(val raw: Long) : AutoCloseable {
    private var closed = false

    override fun close() {
        if (!closed) {
            SheetMusicBridge.nativeReleaseScore(raw)
            closed = true
        }
    }

    protected fun finalize() { close() }

    companion object {
        /** Returns null if Swift parsing failed. */
        fun load(bytes: ByteArray): ScoreHandle? {
            val raw = SheetMusicBridge.nativeLoadScore(bytes)
            return if (raw == 0L) null else ScoreHandle(raw)
        }
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add Examples/Android/app/src/main/java/com/example/sheetmusic/jni/
git commit -m "feat(android-example): Kotlin JNI façade + auto-releasing ScoreHandle"
```

---

### Task 14: ScoreState + ScoreViewModel

**Files:**
- Create: `Examples/Android/app/src/main/java/com/example/sheetmusic/ScoreState.kt`
- Create: `Examples/Android/app/src/main/java/com/example/sheetmusic/ScoreViewModel.kt`

- [ ] **Step 1: `ScoreState.kt`**

```kotlin
package com.example.sheetmusic

import com.example.sheetmusic.draw.DrawProgram

sealed interface ScoreState {
    data object Loading : ScoreState
    data object MissingFixture : ScoreState
    data class ParseError(val message: String) : ScoreState
    data class Ready(
        val program: DrawProgram,
        val currentPage: Int,
        val pageCount: Int,
    ) : ScoreState
}
```

- [ ] **Step 2: `ScoreViewModel.kt`**

```kotlin
package com.example.sheetmusic

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.example.sheetmusic.draw.DrawProgramDecoder
import com.example.sheetmusic.jni.ScoreHandle
import com.example.sheetmusic.jni.SheetMusicBridge
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.FileNotFoundException

private const val ASSET_NAME = "test.mscz"
private const val PAGE_WIDTH_MM = 210.0
private const val PAGE_HEIGHT_MM = 297.0

class ScoreViewModel(app: Application) : AndroidViewModel(app) {

    private val _state = MutableStateFlow<ScoreState>(ScoreState.Loading)
    val state: StateFlow<ScoreState> = _state.asStateFlow()

    private var handle: ScoreHandle? = null

    init { load() }

    fun goToPage(index: Int) {
        val r = _state.value as? ScoreState.Ready ?: return
        if (index in 0 until r.pageCount) {
            _state.value = r.copy(currentPage = index)
        }
    }

    private fun load() {
        viewModelScope.launch {
            val app = getApplication<Application>()
            val bytes = try {
                withContext(Dispatchers.IO) {
                    app.assets.open(ASSET_NAME).use { it.readBytes() }
                }
            } catch (_: FileNotFoundException) {
                _state.value = ScoreState.MissingFixture
                return@launch
            }

            val h = withContext(Dispatchers.Default) {
                ScoreHandle.load(bytes)
            } ?: run {
                _state.value = ScoreState.ParseError("failed to parse $ASSET_NAME")
                return@launch
            }
            handle = h

            val programBytes = withContext(Dispatchers.Default) {
                SheetMusicBridge.nativeComputeLayout(h.raw,
                                                    PAGE_WIDTH_MM, PAGE_HEIGHT_MM)
            }
            if (programBytes.isEmpty()) {
                _state.value = ScoreState.ParseError("layout returned empty result")
                return@launch
            }

            val program = try {
                DrawProgramDecoder.decode(programBytes)
            } catch (e: Exception) {
                _state.value = ScoreState.ParseError(
                    "draw-program decode error: ${e.message}"
                )
                return@launch
            }

            _state.value = ScoreState.Ready(
                program = program,
                currentPage = 0,
                pageCount = program.pages.size.coerceAtLeast(1)
            )
        }
    }

    override fun onCleared() {
        handle?.close()
        super.onCleared()
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add Examples/Android/app/src/main/java/com/example/sheetmusic/ScoreState.kt \
        Examples/Android/app/src/main/java/com/example/sheetmusic/ScoreViewModel.kt
git commit -m "feat(android-example): ScoreState + ScoreViewModel (assets → bridge → decoder)"
```

---

### Task 15: MainActivity, SheetMusicApp, ScoreView, ScoreCanvas, PageControls

**Files:**
- Create: `Examples/Android/app/src/main/java/com/example/sheetmusic/MainActivity.kt`
- Create: `Examples/Android/app/src/main/java/com/example/sheetmusic/SheetMusicApp.kt`
- Create: `Examples/Android/app/src/main/java/com/example/sheetmusic/ScoreView.kt`
- Create: `Examples/Android/app/src/main/java/com/example/sheetmusic/ScoreCanvas.kt`
- Create: `Examples/Android/app/src/main/java/com/example/sheetmusic/PageControls.kt`

- [ ] **Step 1: `MainActivity.kt`**

```kotlin
package com.example.sheetmusic

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { SheetMusicApp() }
    }
}
```

- [ ] **Step 2: `SheetMusicApp.kt`**

```kotlin
package com.example.sheetmusic

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.lifecycle.viewmodel.compose.viewModel

@Composable
fun SheetMusicApp(viewModel: ScoreViewModel = viewModel()) {
    val state by viewModel.state.collectAsState()
    MaterialTheme {
        Surface(modifier = Modifier.fillMaxSize(), color = Color.White) {
            when (val s = state) {
                ScoreState.Loading -> CenteredMessage("Loading …")
                ScoreState.MissingFixture -> MissingFixtureMessage()
                is ScoreState.ParseError -> CenteredMessage("Error: ${s.message}")
                is ScoreState.Ready -> ScoreView(
                    state = s,
                    onPageChange = viewModel::goToPage
                )
            }
        }
    }
}

@Composable
private fun CenteredMessage(text: String) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(text)
    }
}

@Composable
private fun MissingFixtureMessage() {
    Box(
        Modifier.fillMaxSize().background(Color.White).padding(24.dp),
        contentAlignment = Alignment.Center
    ) {
        Text(
            "test.mscz is not bundled.\n\n" +
            "Place a MuseScore file at:\n" +
            "  ~/Desktop/test.mscz\n\n" +
            "Then run:\n" +
            "  Scripts/android-bundle-test-score.sh\n\n" +
            "and rebuild the app.",
            style = MaterialTheme.typography.bodyLarge
        )
    }
}
```

- [ ] **Step 3: `ScoreView.kt`**

```kotlin
package com.example.sheetmusic

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier

@Composable
fun ScoreView(state: ScoreState.Ready, onPageChange: (Int) -> Unit) {
    Box(Modifier.fillMaxSize()) {
        ScoreCanvas(state)
        PageControls(state, onPageChange)
    }
}
```

- [ ] **Step 4: `ScoreCanvas.kt`**

```kotlin
package com.example.sheetmusic

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.input.pointer.pointerInput
import com.example.sheetmusic.draw.DrawCommand
import com.example.sheetmusic.draw.DrawPage

@Composable
fun ScoreCanvas(state: ScoreState.Ready) {
    var scale by remember { mutableFloatStateOf(1f) }
    var offset by remember { mutableStateOf(Offset.Zero) }
    val page = state.program.pages[state.currentPage]
    Canvas(
        modifier = Modifier
            .fillMaxSize()
            .pointerInput(Unit) {
                detectTransformGestures { _, pan, zoom, _ ->
                    scale = (scale * zoom).coerceIn(0.25f, 8f)
                    offset += pan
                }
            }
    ) {
        val pxPerMM = pxPerMM(canvasSizeMM = page.widthMM)
        withTransform({
            translate(offset.x, offset.y)
            scale(scale, scale, pivot = Offset.Zero)
        }) {
            drawPage(page, pxPerMM)
        }
    }
}

private fun DrawScope.pxPerMM(canvasSizeMM: Double): Float =
    (size.width / canvasSizeMM).toFloat()

private fun DrawScope.drawPage(page: DrawPage, pxPerMM: Float) {
    var current = Offset.Zero
    val path = Path()
    var strokeStarted = false
    for (cmd in page.commands) {
        when (cmd) {
            is DrawCommand.MoveTo -> {
                current = Offset(cmd.x.toFloat() * pxPerMM,
                                 cmd.y.toFloat() * pxPerMM)
                if (strokeStarted) { /* discard prior subpath */ path.reset() }
                path.moveTo(current.x, current.y)
                strokeStarted = true
            }
            is DrawCommand.LineTo -> {
                current = Offset(cmd.x.toFloat() * pxPerMM,
                                 cmd.y.toFloat() * pxPerMM)
                path.lineTo(current.x, current.y)
            }
            is DrawCommand.Stroke -> {
                drawPath(
                    path = path,
                    color = Color.Black,
                    style = Stroke(width = (cmd.width.toFloat() * pxPerMM)
                                         .coerceAtLeast(1f))
                )
                path.reset()
                strokeStarted = false
            }
            is DrawCommand.FillRect -> {
                drawRect(
                    color = Color.Black,
                    topLeft = Offset(cmd.x.toFloat() * pxPerMM,
                                     cmd.y.toFloat() * pxPerMM),
                    size = Size(cmd.w.toFloat() * pxPerMM,
                                cmd.h.toFloat() * pxPerMM)
                )
            }
            is DrawCommand.Glyph -> {
                // Phase 4 simplification: render glyphs as small filled
                // squares at the requested position. SMuFL font support is
                // an open question deferred to a follow-up task.
                val s = (cmd.size.toFloat() * pxPerMM) * 0.5f
                drawRect(
                    color = Color.Black,
                    topLeft = Offset(cmd.x.toFloat() * pxPerMM - s / 2,
                                     cmd.y.toFloat() * pxPerMM - s / 2),
                    size = Size(s, s)
                )
            }
            is DrawCommand.Text -> {
                // Same simplification — text rendering deferred. The
                // StubFontMetricsProvider already produces rectangle
                // approximations, so omitting text rendering here is
                // consistent with Phase 2's fidelity statement.
            }
        }
    }
}
```

- [ ] **Step 5: `PageControls.kt`**

```kotlin
package com.example.sheetmusic

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

@Composable
fun PageControls(state: ScoreState.Ready, onPageChange: (Int) -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.SpaceBetween
    ) {
        TextButton(
            onClick = { onPageChange(state.currentPage - 1) },
            enabled = state.currentPage > 0
        ) { Text("Prev") }

        Text("${state.currentPage + 1} / ${state.pageCount}")

        TextButton(
            onClick = { onPageChange(state.currentPage + 1) },
            enabled = state.currentPage < state.pageCount - 1
        ) { Text("Next") }

        IconButton(
            onClick = {},
            enabled = false
        ) {
            Icon(
                Icons.Default.PlayArrow,
                contentDescription = "Play (available after Phase 3 — SheetMusicAudioCore)"
            )
        }
    }
}
```

- [ ] **Step 6: Build the app from CLI**

```bash
cd Examples/Android && ./gradlew :app:assembleDebug && cd ../..
```
Expected: `assembleDebug` succeeds. Compose compiler emits no errors.

> **Plan note:** if Gradle fails because `jniLibs/` is empty, run `Scripts/android-build-libs.sh` first.

- [ ] **Step 7: Commit**

```bash
git add Examples/Android/app/src/main/java/com/example/sheetmusic/
git commit -m "feat(android-example): Compose UI — MainActivity / ScoreView / Canvas / PageControls"
```

---

### Task 16: Examples/Android/README.md

**Files:**
- Create: `Examples/Android/README.md`

- [ ] **Step 1: Write README**

```markdown
# SheetMusic — Android Compose example

An end-to-end Kotlin Compose demo that parses an `.mscz` and renders it
to a Compose `Canvas` using the cross-compiled `SheetMusicAndroidJNI`
Swift library.

Audio is intentionally disabled; the Play button is shown but greyed
out. Wiring up `SheetMusicAudioCore` is a Phase 4 follow-up that lands
after Phase 3 (`feature/audio-backend-di`) merges.

## Prerequisites

- macOS or Linux host
- Open-source Swift 6.3.2-RELEASE toolchain installed (see the project
  root `CLAUDE.md` "Android build" section for the install command and
  `TOOLCHAINS` env var)
- Swift Android SDK 6.3.2-RELEASE_android-0.1 installed (`swift sdk list`
  should report it)
- One-time NDK sysroot symlink setup completed (see root `CLAUDE.md`)
- Android Studio Hedgehog or later, JDK 17
- A physical Android device or emulator on API 28 or higher (arm64 or
  x86_64)

## Quickstart

```bash
# from the repo root:
Scripts/android-build-libs.sh        # cross-compile + stage .so per ABI

# Provide your own MuseScore file (this is gitignored and never committed)
cp /path/to/your/file.mscz ~/Desktop/test.mscz
Scripts/android-bundle-test-score.sh # copies it into Examples/Android/app/src/main/assets/

# Open the example in Android Studio
open -a "Android Studio" Examples/Android
```

Press Run. The app loads `test.mscz`, parses + lays out via the Swift
library through the JNI bridge, and renders page 1 onto the Compose
Canvas. Pinch / drag to zoom and pan; use Prev / Next for page
navigation.

## What this does NOT do

- Play audio — the icon is disabled until Phase 3 lands.
- Edit the score.
- Export to PDF.
- Use a real SMuFL music font. Phase 2's `StubFontMetricsProvider`
  generates rectangle approximations for glyphs; the Compose canvas
  renders them as small filled squares.

## Troubleshooting

- `UnsatisfiedLinkError: libSheetMusicJNI.so` — run
  `Scripts/android-build-libs.sh`. Confirm both
  `Examples/Android/app/src/main/jniLibs/arm64-v8a/libSheetMusicJNI.so`
  and `Examples/Android/app/src/main/jniLibs/x86_64/libSheetMusicJNI.so`
  exist.
- App starts but shows "test.mscz is not bundled." — run
  `Scripts/android-bundle-test-score.sh` after putting a MuseScore file
  at `~/Desktop/test.mscz`. Then rebuild and reinstall.
- `'semaphore.h' file not found` during Swift cross-compile — the NDK
  sysroot symlink wasn't set up. See root `CLAUDE.md` "One-time NDK
  sysroot setup".
- App crashes on launch with SEGV — the Swift runtime stubs may be
  missing in `jniLibs/<abi>/`. `Scripts/android-build-libs.sh` copies
  them automatically; confirm `libswiftCore.so` is present.
- Gradle sync fails because a `jniLibs/` directory is empty — that's
  fine for sync, but `assembleDebug` will fail at link time. Run the
  build script first.

## Layout

```
Examples/Android/
├── app/
│   ├── build.gradle.kts
│   └── src/main/
│       ├── AndroidManifest.xml
│       ├── assets/test.mscz        (gitignored; supplied by you)
│       ├── jniLibs/<abi>/*.so      (built by Scripts/android-build-libs.sh)
│       └── java/com/example/sheetmusic/
│           ├── MainActivity        # entry point
│           ├── SheetMusicApp       # state routing
│           ├── ScoreViewModel      # load / parse / layout pipeline
│           ├── ScoreState          # sealed state machine
│           ├── ScoreView           # ScoreCanvas + PageControls
│           ├── ScoreCanvas         # Compose Canvas + pan/zoom
│           ├── PageControls        # prev / next / disabled play
│           ├── draw/DrawProgramDecoder    # parses the binary stream
│           └── jni/SheetMusicBridge       # external fun + System.loadLibrary
```
```

- [ ] **Step 2: Commit**

```bash
git add Examples/Android/README.md
git commit -m "docs(android-example): quickstart + troubleshooting README"
```

---

### Task 17: Update root `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

The Phase 3 worktree (`audio-backend-di`) is also editing this file. Per
the spec's risk note, this plan assumes Phase 3 merges first. If the
order swaps, the conflict is straightforward to resolve (different
subsections).

- [ ] **Step 1: Read current "Android build" section**

```bash
grep -n "Android build\|UI / PDF\|Things not to do" CLAUDE.md
```

- [ ] **Step 2: Edit "Android build" section**

Locate the line:

```
UI / PDF / Audio remain Apple-only pending Phase 3 audio DI.
```

(or its Phase-3-merged equivalent, e.g. `UI / PDF remain Apple-only pending Phase 4`)

Replace with:

```
UI / PDF remain Apple-only.
```

Append a new subsection right after the "Format support on Android"
subsection:

```markdown
### Android example app

An end-to-end Kotlin Compose demo lives in `Examples/Android/`. It
parses an `.mscz` from the app's `assets/`, computes layout via the
JNI bridge (`Sources/SheetMusicAndroidJNI`), and renders pages to a
Compose `Canvas`. Audio is intentionally not wired (the Play button
is disabled) — wiring is a follow-up after `SheetMusicAudioCore` lands
from Phase 3.

Quickstart (from repo root):

    # 1. Build native libs into Examples/Android/app/src/main/jniLibs/
    Scripts/android-build-libs.sh

    # 2. Copy a MuseScore file you own into the app's assets
    cp /path/to/your.mscz ~/Desktop/test.mscz
    Scripts/android-bundle-test-score.sh

    # 3. Open Examples/Android/ in Android Studio and Run

Supported ABIs: `arm64-v8a`, `x86_64`. Lowest API level: 28.
Glyph rendering uses `StubFontMetricsProvider` rectangle approximations
on Android — replacing with a SMuFL-aware Android provider is a future
phase.
```

- [ ] **Step 3: Append to "Things not to do"**

Add a bullet:

```markdown
- Don't commit `Examples/Android/app/src/main/assets/test.mscz` — the
  file is for local testing only and not redistributable. The bundle
  script (`Scripts/android-bundle-test-score.sh`) copies it from
  `~/Desktop` and the destination is gitignored.
```

- [ ] **Step 4: Verify**

```bash
grep -n "Examples/Android\|StubFontMetricsProvider rectangle\|test.mscz" CLAUDE.md
```
Expected: at least the three additions are present and worded correctly.

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(android-example): add CLAUDE.md quickstart + gitignore-bundle warning"
```

---

### Task 18: End-to-end verification on emulator + device

This task is manual — runs the matrix from the spec's Verification
section. The implementer must record the outcome of each step in the
task notes; failure of any step is a blocker (not a defer).

- [ ] **Step 1: Apple host build + tests**

```bash
swift build
swift test 2>&1 | tail -5
```
Expected: build green, 100% tests pass.

- [ ] **Step 2: Android cross-compile (arm64)**

```bash
SWIFT_SHEET_MUSIC_ANDROID=1 TOOLCHAINS=org.swift.632202605101a \
    swift build --swift-sdk aarch64-unknown-linux-android28 --build-tests
```
Expected: success.

- [ ] **Step 3: Android cross-compile (x86_64)**

```bash
SWIFT_SHEET_MUSIC_ANDROID=1 TOOLCHAINS=org.swift.632202605101a \
    swift build --swift-sdk x86_64-unknown-linux-android28
```
Expected: success.

- [ ] **Step 4: Package manifest both shapes**

```bash
swift package describe --type json | jq -r '.targets[] | .name' | sort > /tmp/apple.txt
SWIFT_SHEET_MUSIC_ANDROID=1 swift package describe --type json | \
    jq -r '.targets[] | .name' | sort > /tmp/android.txt
diff /tmp/apple.txt /tmp/android.txt
```
Expected: Apple-only and Android-only target deltas match the spec
(Android-only: CJNI; Apple-only: SheetMusicLayoutApple / SheetMusicUI /
SheetMusicAudio / SheetMusicPDF / RenderPreviews).

- [ ] **Step 5: Build native libs**

```bash
Scripts/android-build-libs.sh
ls Examples/Android/app/src/main/jniLibs/arm64-v8a/
ls Examples/Android/app/src/main/jniLibs/x86_64/
```
Expected: each dir contains `libSheetMusicJNI.so` plus runtime stubs.

- [ ] **Step 6: Bundle the test score**

```bash
Scripts/android-bundle-test-score.sh
ls -la Examples/Android/app/src/main/assets/test.mscz
```
Expected: file exists and matches `~/Desktop/test.mscz`.

- [ ] **Step 7: Gradle build (both ABIs)**

```bash
cd Examples/Android && ./gradlew :app:assembleDebug && cd ../..
```
Expected: APK at `Examples/Android/app/build/outputs/apk/debug/app-debug.apk`.

- [ ] **Step 8: Install + launch on emulator**

Start an Android emulator at API 28+ (arm64 image on Apple Silicon, or
x86_64 image on Intel). Then:

```bash
adb install -r Examples/Android/app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n com.example.sheetmusic/.MainActivity
```

Expected: app launches without `UnsatisfiedLinkError`. Score renders
within a few seconds. Pinch / drag work. Prev / Next cycles pages
(if `test.mscz` has more than one page).

- [ ] **Step 9: MissingFixture path**

```bash
mv Examples/Android/app/src/main/assets/test.mscz /tmp/test.mscz.bak
cd Examples/Android && ./gradlew :app:assembleDebug && cd ../..
adb install -r Examples/Android/app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n com.example.sheetmusic/.MainActivity
```
Expected: app shows the "test.mscz is not bundled" message screen.

Restore:
```bash
mv /tmp/test.mscz.bak Examples/Android/app/src/main/assets/test.mscz
```

- [ ] **Step 10: Confirm existing Android library tests still green**

```bash
Scripts/android-test.sh aarch64
```
Expected: same pass count as before Phase 4 (Foundation-only library
targets are unaffected).

- [ ] **Step 11: Confirm Apple example schemes still build**

Per memory `feedback_example_app_outside_swiftpm`:

```bash
xcodebuild -project Example/SheetMusicExample.xcodeproj \
           -scheme SheetMusicExample \
           -destination 'platform=iOS Simulator,name=iPhone 17' \
           build
xcodebuild -project Example/SheetMusicExample.xcodeproj \
           -scheme SheetMusicExampleMac \
           build
```
(Re-run `cd Example && xcodegen` first if the project is out of date.)
Expected: both schemes build green.

- [ ] **Step 12: Visual sanity check**

Render the same `test.mscz` in `SheetMusicExampleMac` (per memory
`feedback_visual_verify_mac`) and screenshot. Compare to the Android
emulator screenshot. The Android version will look "skeletal" (no
real glyphs, rectangle placeholders) — this is expected. The page
size, staff line positions, and overall layout should match.

- [ ] **Step 13: Commit verification notes**

If any minor doc tweak emerged from verification (e.g. a missing
runtime `.so` name in the build script), commit it here:

```bash
git add -A
git commit -m "fix(android-example): verification follow-ups"
```

If nothing to commit, skip.

---

### Task 19: Update memory

> **Plan note:** memory updates are NOT a git-tracked artifact; they live
> in `~/.claude/projects/.../memory/`. Run this task only after Task 18
> passes end-to-end. Do not skip — the next session needs accurate state.

- [ ] **Step 1: Update `project_android_port_roadmap.md`**

Read the current contents, then append:

```
2026-05-19 Phase 4 (audio-deferred subset) status: complete

  - Examples/Android/ Compose app: parse → layout → Canvas render ✅
  - Sources/SheetMusicAndroidJNI/ + Sources/CJNI/ ✅
  - Scripts/android-build-libs.sh (arm64-v8a + x86_64) ✅
  - Scripts/android-bundle-test-score.sh ✅
  - Audio playback: deferred — wires up SheetMusicAudioCore after
    Phase 3 merge

Remaining Phase 4 follow-ups:
  - Wire SheetMusicAudioCore-based playback once Phase 3 lands
  - armv7 ABI (low priority; defer until requested)
  - Android-native font metrics provider (replace
    StubFontMetricsProvider)
  - Real SMuFL glyph rendering in Compose Canvas
  - Editing UI (note input, selection, etc.) — own phase
```

Update the `description` frontmatter line if the existing summary is
now stale.

- [ ] **Step 2: Create `project_android_compose_example.md`**

```markdown
---
name: project-android-compose-example
description: Android Compose example app — JNI bridge location, draw-program rationale, test.mscz workflow, Phase 3 audio wiring
metadata:
  type: project
---

The Android Compose example lives at `Examples/Android/`. The JNI
bridge is `Sources/SheetMusicAndroidJNI/` with `@_cdecl` symbols
gated `#if os(Android)` so encoder / handle logic can be unit-tested
on Apple via `swift test`. The dynamic library product
`SheetMusicJNI` is only registered when `SWIFT_SHEET_MUSIC_ANDROID=1`.

LayoutDocument crosses the JNI boundary as a flat little-endian
"draw program" byte array. Format is defined in
`Sources/SheetMusicAndroidJNI/DrawProgram.swift`. Encoder (Swift) and
decoder (Kotlin `Examples/Android/app/.../draw/DrawProgramDecoder.kt`)
must stay in lockstep; the `version` field in the header fails fast
on mismatch. Adding a new opcode is a two-file commit (both sides).

`test.mscz` workflow: developer drops a MuseScore file at
`~/Desktop/test.mscz`. `Scripts/android-bundle-test-score.sh` copies
it into `Examples/Android/app/src/main/assets/test.mscz`. The
destination is gitignored. Missing-asset state surfaces a runtime
message screen telling the developer to run the script. See
[[project-android-port-roadmap]].

**Phase 3 audio wiring procedure** (after Phase 3 merges):

1. Add `SheetMusicAudioCore` to `SheetMusicAndroidJNI`'s dependencies.
2. Add `@_cdecl` entry points for the audio surface
   (`Java_com_example_sheetmusic_jni_SheetMusicBridge_nativePlay…`).
3. Replace `enabled = false` on the Play `IconButton` in
   `PageControls.kt`.
4. Add a Kotlin `PlaybackViewModel` that bridges into the Swift
   `PlaybackTimeline` via JNI and drives an Android `AudioTrack` /
   `OAboe` sink.

**How to apply:** consult this memory when extending the Android
example, when touching the draw-program format on either side, or
when wiring audio after Phase 3 lands.
```

- [ ] **Step 3: Add pointer to `MEMORY.md`**

Append one line under the existing Android entry:

```
- [Android Compose example](project_android_compose_example.md) — JNI bridge location, flat draw-program rationale, test.mscz workflow, Phase 3 audio wiring procedure
```

- [ ] **Step 4: Commit nothing**

Memory lives outside the repo. No git commit here.

---

## Self-review (run before merge)

Done after Task 19 passes end-to-end:

- [ ] Spec coverage: every section in
  `docs/superpowers/specs/2026-05-19-android-compose-example-design.md`
  is implemented or explicitly deferred. The deferred list is captured
  in Task 19 follow-ups.
- [ ] All commits compile in isolation (each task's final `swift build`
  or `./gradlew` step passed).
- [ ] No `SheetMusicAndroidJNI` symbols are referenced from Apple-only
  code paths (the target is consumable from Apple but the JNI symbols
  are `#if os(Android)`).
- [ ] `Scripts/android-build-libs.sh` and
  `Scripts/android-bundle-test-score.sh` are committed with `+x` mode.
- [ ] `Examples/Android/.gitignore` ignores `assets/test.mscz` and
  `jniLibs/`.
- [ ] `CLAUDE.md` updates do NOT conflict with Phase 3's edits (or
  the conflict was resolved).
- [ ] Memory files saved to
  `~/.claude/projects/.../memory/` and `MEMORY.md` updated.

Once the self-review passes, run `superpowers:finishing-a-development-branch` to choose the merge strategy.
