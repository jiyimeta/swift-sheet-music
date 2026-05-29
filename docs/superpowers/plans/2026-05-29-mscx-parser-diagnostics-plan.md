# MSCX parser diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make embellishment-class MSCX decode failures non-fatal warnings (`ScoreDiagnostic`) instead of aborting the parse, surfaced via a new `parseWithDiagnostics(...)` sibling API while keeping existing callers fully working.

**Architecture:** Add `ScoreDiagnostic` to Core, `MSCXParseResult` + `MSCXDiagnosticCollector` to MSCX. Thread the collector through decoders via a `@TaskLocal` (no signature changes for decoders that have nothing to report). Convert the three `Tremolo` decoder throws into `nil + collector.warn(...)`, and reroute three existing `mscxDecoderLogger.warning(...)` sites through a `mscxDecoderWarn` helper that fans out to both `Logger` and the collector.

**Tech Stack:** Swift 6.3, Swift Testing (`import Testing`), Foundation, `os.Logger`, SwiftPM. Tests run via `swift test --filter <suite>`. Spec source: `docs/superpowers/specs/2026-05-29-mscx-parser-diagnostics-design.md`.

**Working directory:** `.claude/worktrees/parser-diagnostics` on branch `feature/parser-diagnostics`. All paths below are relative to this worktree root.

---

## File Structure Overview

```
Sources/SheetMusicCore/
  ScoreDiagnostic.swift                                 (new — value type)

Sources/SheetMusicMSCX/
  MSCXParseResult.swift                                 (new — value type)
  MSCXParser.swift                                      (+ 2 parseWithDiagnostics overloads)
  MSCZReader.swift                                      (+ 2 parseWithDiagnostics overloads)
  Diagnostics/
    MSCXDiagnosticCollector.swift                       (new — final class @unchecked Sendable)
    MSCXParserContext.swift                             (new — @TaskLocal holder)
    MSCXDecoderWarn.swift                               (new — fan-out helper)
  Decoders/
    MSCXDecoder+Tremolo.swift                           (throws → diagnostic + nil)
    MSCXDecoder+Chord.swift                             (handle nil from Tremolo.decode)
    MSCXDecoder+Score.swift                             (2 logger.warning → mscxDecoderWarn)
    MSCXDecoder+Breath.swift                            (1 logger.warning → mscxDecoderWarn)

Tests/SheetMusicTests/
  MSCXDiagnosticsTests.swift                            (new — 6 cases)
  TremoloMSCXDecodeTests.swift                          (rewrite `unknown_subtype_throws`)
  Resources/own/
    LICENSE                                             (new — MIT scope notice)
    diagnostics-tremolo-unknown-subtype.mscx            (new — minimal fixture)

CLAUDE.md                                               (extend "Permissive parser" bullet)
```

`Resources/own/` does not need a Package.swift change — the test target already declares `.process("Resources")`, so subdirectories of `Resources/` are picked up automatically.

---

### Task 1: `ScoreDiagnostic` value type in Core

**Files:**
- Create: `Sources/SheetMusicCore/ScoreDiagnostic.swift`
- Create: `Tests/SheetMusicTests/Core/ScoreDiagnosticTests.swift` (new sub-dir is fine; existing tests live flat under `Tests/SheetMusicTests/`, but a `Core/` subfolder is acceptable and tidy)

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/Core/ScoreDiagnosticTests.swift`:

```swift
import Testing
@testable import SheetMusicCore

@Suite struct ScoreDiagnosticTests {
    @Test func constructs_with_all_fields() {
        let d = ScoreDiagnostic(
            severity: .warning,
            code: "mscx.tremolo.unknownSubtype",
            message: "Tremolo unknown <subtype> r128",
            location: "measure 1, voice 1, Tremolo",
        )
        #expect(d.severity == .warning)
        #expect(d.code == "mscx.tremolo.unknownSubtype")
        #expect(d.message == "Tremolo unknown <subtype> r128")
        #expect(d.location == "measure 1, voice 1, Tremolo")
    }

    @Test func location_defaults_to_nil() {
        let d = ScoreDiagnostic(
            severity: .info,
            code: "mscx.test",
            message: "hello",
        )
        #expect(d.location == nil)
    }

    @Test func is_hashable_and_equatable() {
        let a = ScoreDiagnostic(severity: .warning, code: "x", message: "y")
        let b = ScoreDiagnostic(severity: .warning, code: "x", message: "y")
        let c = ScoreDiagnostic(severity: .info, code: "x", message: "y")
        #expect(a == b)
        #expect(a != c)
        #expect(Set([a, b, c]).count == 2)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ScoreDiagnosticTests`
Expected: FAIL — `cannot find 'ScoreDiagnostic' in scope`

- [ ] **Step 3: Implement `ScoreDiagnostic`**

Create `Sources/SheetMusicCore/ScoreDiagnostic.swift`:

```swift
import Foundation

/// Non-fatal anomaly observed while parsing a score. Collected by
/// `MSCXParser.parseWithDiagnostics(...)` / `MSCZReader.parseWithDiagnostics(...)`
/// instead of being thrown, so callers can recover partial data and
/// surface a warning UI.
public struct ScoreDiagnostic: Sendable, Hashable {
    public enum Severity: Sendable, Hashable {
        /// Recoverable: the offending element was dropped or defaulted.
        case warning
        /// Notable but expected (e.g. MS2 compatibility path).
        case info
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

    public init(
        severity: Severity,
        code: String,
        message: String,
        location: String? = nil,
    ) {
        self.severity = severity
        self.code = code
        self.message = message
        self.location = location
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ScoreDiagnosticTests`
Expected: PASS — 3 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicCore/ScoreDiagnostic.swift \
        Tests/SheetMusicTests/Core/ScoreDiagnosticTests.swift
git commit -m "feat(core): add ScoreDiagnostic value type"
```

---

### Task 2: `MSCXDiagnosticCollector` + `MSCXParserContext` (TaskLocal)

**Files:**
- Create: `Sources/SheetMusicMSCX/Diagnostics/MSCXDiagnosticCollector.swift`
- Create: `Sources/SheetMusicMSCX/Diagnostics/MSCXParserContext.swift`
- Create: `Tests/SheetMusicTests/MSCXDiagnosticCollectorTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/MSCXDiagnosticCollectorTests.swift`:

```swift
import Testing
@testable import SheetMusicCore
@testable import SheetMusicMSCX

@Suite struct MSCXDiagnosticCollectorTests {
    @Test func warn_appends_warning_entry() {
        let c = MSCXDiagnosticCollector()
        c.warn(code: "mscx.test", message: "hello")
        #expect(c.entries.count == 1)
        #expect(c.entries[0].severity == .warning)
        #expect(c.entries[0].code == "mscx.test")
        #expect(c.entries[0].message == "hello")
        #expect(c.entries[0].location == nil)
    }

    @Test func info_appends_info_entry_with_location() {
        let c = MSCXDiagnosticCollector()
        c.info(code: "mscx.score.ms2", message: "MS2 path", location: "Score")
        #expect(c.entries.count == 1)
        #expect(c.entries[0].severity == .info)
        #expect(c.entries[0].location == "Score")
    }

    @Test func task_local_starts_nil() {
        #expect(MSCXParserContext.collector == nil)
    }

    @Test func task_local_scopes_collector() {
        let c = MSCXDiagnosticCollector()
        MSCXParserContext.$collector.withValue(c) {
            #expect(MSCXParserContext.collector === c)
        }
        #expect(MSCXParserContext.collector == nil)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MSCXDiagnosticCollectorTests`
Expected: FAIL — symbols not in scope.

- [ ] **Step 3: Implement `MSCXDiagnosticCollector`**

Create `Sources/SheetMusicMSCX/Diagnostics/MSCXDiagnosticCollector.swift`:

```swift
import Foundation
import SheetMusicCore

/// Collects `ScoreDiagnostic` entries during a single MSCX parse call.
/// Owned for the lifetime of one `parseWithDiagnostics(...)` invocation;
/// not intended for sharing across parses or threads.
///
/// `@unchecked Sendable`: the collector is mutated through its reference
/// during a single-threaded parse, then handed off as a snapshot via
/// `MSCXParseResult`. No concurrent access occurs in practice.
final class MSCXDiagnosticCollector: @unchecked Sendable {
    private(set) var entries: [ScoreDiagnostic] = []

    func warn(
        code: String,
        message: String,
        location: String? = nil,
    ) {
        entries.append(ScoreDiagnostic(
            severity: .warning,
            code: code,
            message: message,
            location: location,
        ))
    }

    func info(
        code: String,
        message: String,
        location: String? = nil,
    ) {
        entries.append(ScoreDiagnostic(
            severity: .info,
            code: code,
            message: message,
            location: location,
        ))
    }
}
```

- [ ] **Step 4: Implement `MSCXParserContext`**

Create `Sources/SheetMusicMSCX/Diagnostics/MSCXParserContext.swift`:

```swift
import Foundation

/// TaskLocal stash that lets decoders find the active
/// `MSCXDiagnosticCollector` without threading it through every
/// signature. Set by `MSCXParser.parseWithDiagnostics(...)` and
/// `MSCZReader.parseWithDiagnostics(...)`; nil outside those scopes
/// (in which case decoders skip the diagnostic and behave exactly as
/// before).
enum MSCXParserContext {
    @TaskLocal static var collector: MSCXDiagnosticCollector?
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter MSCXDiagnosticCollectorTests`
Expected: PASS — 4 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicMSCX/Diagnostics/MSCXDiagnosticCollector.swift \
        Sources/SheetMusicMSCX/Diagnostics/MSCXParserContext.swift \
        Tests/SheetMusicTests/MSCXDiagnosticCollectorTests.swift
git commit -m "feat(mscx): add MSCXDiagnosticCollector + MSCXParserContext"
```

---

### Task 3: `MSCXParseResult` + `mscxDecoderWarn` helper

**Files:**
- Create: `Sources/SheetMusicMSCX/MSCXParseResult.swift`
- Create: `Sources/SheetMusicMSCX/Diagnostics/MSCXDecoderWarn.swift`
- Modify: `Tests/SheetMusicTests/MSCXDiagnosticCollectorTests.swift` (extend)

- [ ] **Step 1: Write the failing test (extend the existing suite)**

Append to `Tests/SheetMusicTests/MSCXDiagnosticCollectorTests.swift`:

```swift
@Suite struct MSCXDecoderWarnTests {
    @Test func warn_helper_appends_to_active_collector() {
        let c = MSCXDiagnosticCollector()
        MSCXParserContext.$collector.withValue(c) {
            mscxDecoderWarn(
                code: "mscx.test",
                message: "hi",
                location: "x",
            )
        }
        #expect(c.entries.count == 1)
        #expect(c.entries[0].code == "mscx.test")
        #expect(c.entries[0].location == "x")
    }

    @Test func warn_helper_is_no_op_without_active_collector() {
        // Must not crash when no collector is in scope. Outside withValue,
        // `MSCXParserContext.collector` is nil.
        mscxDecoderWarn(code: "mscx.test", message: "hi")
        // (No assertion needed beyond the call not throwing / crashing.)
    }
}

@Suite struct MSCXParseResultTests {
    @Test func has_score_and_diagnostics() throws {
        // Use the smallest possible bundled fixture to avoid pulling in
        // additional XML parsing here — construct directly.
        // We can't easily build a Score in isolation, so just verify
        // the wrapper compiles and exposes the two fields. Use Mirror
        // instead of constructing a Score by hand.
        let result = MSCXParseResult.empty()
        #expect(result.diagnostics.isEmpty)
        // `score` is non-optional; if accessing compiles, the contract
        // is satisfied for this smoke check.
        _ = result.score
    }
}

private extension MSCXParseResult {
    /// Test helper that fabricates an empty Score so we can construct
    /// an MSCXParseResult without going through a real parse.
    static func empty() -> MSCXParseResult {
        MSCXParseResult(
            score: Score(division: 480, parts: []),
            diagnostics: [],
        )
    }
}
```

> Verified: `Score.init` has only one required parameter (`division: Int`); the rest default. `Score(division: 480, parts: [])` compiles as written.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter "MSCXDecoderWarnTests|MSCXParseResultTests"`
Expected: FAIL — `MSCXParseResult` / `mscxDecoderWarn` not in scope.

- [ ] **Step 3: Implement `MSCXParseResult`**

Create `Sources/SheetMusicMSCX/MSCXParseResult.swift`:

```swift
import Foundation
import SheetMusicCore

/// Result of an MSCX / MSCZ parse that surfaces non-fatal anomalies
/// alongside the parsed score. Returned by
/// `MSCXParser.parseWithDiagnostics(...)` /
/// `MSCZReader.parseWithDiagnostics(...)`. The matching
/// `parse(...) -> Score` overloads share the same internal decode
/// path but discard `diagnostics`.
public struct MSCXParseResult: Sendable {
    public let score: Score
    public let diagnostics: [ScoreDiagnostic]

    public init(score: Score, diagnostics: [ScoreDiagnostic]) {
        self.score = score
        self.diagnostics = diagnostics
    }
}
```

- [ ] **Step 4: Implement `mscxDecoderWarn`**

Create `Sources/SheetMusicMSCX/Diagnostics/MSCXDecoderWarn.swift`:

```swift
import Foundation
#if canImport(os)
    import os
#endif

/// Emit a parser warning to both the active `MSCXDiagnosticCollector`
/// (when one is in scope) and `mscxDecoderLogger` (on platforms where
/// `os.Logger` is available). Used by decoders to surface anomalies
/// that don't warrant aborting the parse.
///
/// When called outside a `parseWithDiagnostics(...)` scope the
/// collector arm is a no-op; the `Logger` arm still runs so existing
/// console output is unchanged.
func mscxDecoderWarn(
    code: String,
    message: String,
    location: String? = nil,
) {
    #if canImport(os)
        let locationSuffix = location.map { " (\($0))" } ?? ""
        mscxDecoderLogger.warning(
            "\(code, privacy: .public): \(message, privacy: .public)\(locationSuffix, privacy: .public)",
        )
    #endif
    MSCXParserContext.collector?.warn(
        code: code, message: message, location: location,
    )
}
```

> `mscxDecoderLogger` is declared in `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Score.swift` at file scope under `#if canImport(os)`. The helper above references it from the `Diagnostics/` directory — both files are in the same module, so the file-private-or-not-private decision matters. Verify `mscxDecoderLogger` is `internal` (no `private` / `fileprivate` modifier). If it is `fileprivate`, change it to `internal` (drop the modifier) in `MSCXDecoder+Score.swift` as part of this step.

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter "MSCXDecoderWarnTests|MSCXParseResultTests"`
Expected: PASS — 3 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicMSCX/MSCXParseResult.swift \
        Sources/SheetMusicMSCX/Diagnostics/MSCXDecoderWarn.swift \
        Tests/SheetMusicTests/MSCXDiagnosticCollectorTests.swift
# If MSCXDecoder+Score.swift was edited only to drop `fileprivate`:
git add Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Score.swift
git commit -m "feat(mscx): add MSCXParseResult and mscxDecoderWarn helper"
```

---

### Task 4: `parseWithDiagnostics` public API (clean-file path)

**Files:**
- Modify: `Sources/SheetMusicMSCX/MSCXParser.swift`
- Modify: `Sources/SheetMusicMSCX/MSCZReader.swift`
- Create: `Tests/SheetMusicTests/MSCXDiagnosticsTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/MSCXDiagnosticsTests.swift`:

```swift
import Foundation
import Testing
@testable import SheetMusicCore
@testable import SheetMusicMSCX

@Suite struct MSCXDiagnosticsTests {
    @Test func cleanFile_yieldsEmptyDiagnostics_mscx() throws {
        let url = Bundle.module.url(
            forResource: "midi01", withExtension: "mscx",
        )!
        let result = try MSCXParser.parseWithDiagnostics(contentsOf: url)
        #expect(result.diagnostics.isEmpty)
        #expect(!result.score.parts.isEmpty)
    }

    @Test func cleanFile_yieldsEmptyDiagnostics_mscz() throws {
        let url = Bundle.module.url(
            forResource: "midi01", withExtension: "mscz",
        )!
        let result = try MSCZReader.parseWithDiagnostics(contentsOf: url)
        #expect(result.diagnostics.isEmpty)
        #expect(!result.score.parts.isEmpty)
    }
}
```

> `midi01.mscx` / `midi01.mscz` already exist under `Tests/SheetMusicTests/Resources/` — confirmed via `ls Tests/SheetMusicTests/Resources/ | grep midi01`.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MSCXDiagnosticsTests`
Expected: FAIL — `parseWithDiagnostics` not in scope.

- [ ] **Step 3: Add `parseWithDiagnostics` to `MSCXParser`**

Replace the contents of `Sources/SheetMusicMSCX/MSCXParser.swift` with:

```swift
import Foundation
import SheetMusicCore
import SheetMusicXMLTools

/// Public façade that turns mscx XML bytes into a `Score`.
public enum MSCXParser {
    /// Parse uncompressed `.mscx` XML bytes into an in-memory `Score`.
    /// Throws `SheetMusicError.invalidXML` for ill-formed XML and
    /// `SheetMusicError.malformedScore` for missing required elements.
    ///
    /// Non-fatal anomalies (e.g. unknown embellishment subtypes) are
    /// dropped silently. Use `parseWithDiagnostics(_:)` to receive them.
    public static func parse(_ data: Data) throws -> Score {
        let root = try XMLTreeParser.parse(data)
        return try Score.decode(root)
    }

    /// Read `.mscx` XML from a file URL and parse into a `Score`.
    /// I/O failures are wrapped in `SheetMusicError.ioError`.
    public static func parse(contentsOf url: URL) throws -> Score {
        let data = try readData(at: url)
        return try parse(data)
    }

    /// Parse `.mscx` XML bytes, returning the score together with any
    /// non-fatal anomalies observed during decoding (unknown
    /// embellishment subtypes, MS2 compat warnings, …). Throws the same
    /// errors as `parse(_:)` — structural problems still abort.
    public static func parseWithDiagnostics(
        _ data: Data,
    ) throws -> MSCXParseResult {
        let collector = MSCXDiagnosticCollector()
        let score = try MSCXParserContext.$collector.withValue(collector) {
            try parse(data)
        }
        return MSCXParseResult(score: score, diagnostics: collector.entries)
    }

    /// Read `.mscx` XML from a file URL and parse with diagnostics.
    public static func parseWithDiagnostics(
        contentsOf url: URL,
    ) throws -> MSCXParseResult {
        let data = try readData(at: url)
        return try parseWithDiagnostics(data)
    }

    private static func readData(at url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw SheetMusicError.ioError(url: url, underlying: error)
        }
    }
}
```

- [ ] **Step 4: Add `parseWithDiagnostics` to `MSCZReader`**

In `Sources/SheetMusicMSCX/MSCZReader.swift`, add two methods inside the existing `public enum MSCZReader { … }` block (alongside the existing `parse` overloads). The simplest spelling delegates to `MSCXParser.parseWithDiagnostics` for the inner decode, and applies `audioSettings` post-processing exactly as the throwing version does:

```swift
    /// Parse `.mscz` bytes, returning the score with non-fatal
    /// anomalies. Behaves like `parse(_:)` but surfaces diagnostics
    /// from the inner MSCX decode.
    public static func parseWithDiagnostics(
        _ data: Data,
    ) throws -> MSCXParseResult {
        let reader = try openReader(data)
        let mainPath = try resolveMainPath(in: reader)
        let mscxData: Data
        do {
            mscxData = try reader.read(path: mainPath)
        } catch let error as ZipError {
            throw SheetMusicError.corruptedContainer(
                reason: "failed to extract \(mainPath): \(error)",
            )
        }
        let inner = try MSCXParser.parseWithDiagnostics(mscxData)
        let settings = audioSettings(in: reader)
        let finalScore = settings.map { apply($0, to: inner.score) } ?? inner.score
        return MSCXParseResult(score: finalScore, diagnostics: inner.diagnostics)
    }

    /// Read `.mscz` bytes from a file URL and parse with diagnostics.
    public static func parseWithDiagnostics(
        contentsOf url: URL,
    ) throws -> MSCXParseResult {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SheetMusicError.ioError(url: url, underlying: error)
        }
        return try parseWithDiagnostics(data)
    }
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter MSCXDiagnosticsTests`
Expected: PASS — 2 tests.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicMSCX/MSCXParser.swift \
        Sources/SheetMusicMSCX/MSCZReader.swift \
        Tests/SheetMusicTests/MSCXDiagnosticsTests.swift
git commit -m "feat(mscx): add parseWithDiagnostics public API"
```

---

### Task 5: MIT-licensed test fixture for the diagnostic path

**Files:**
- Create: `Tests/SheetMusicTests/Resources/own/LICENSE`
- Create: `Tests/SheetMusicTests/Resources/own/diagnostics-tremolo-unknown-subtype.mscx`
- Modify: `Tests/SheetMusicTests/MSCXDiagnosticsTests.swift` (add resource-resolution sanity test)

- [ ] **Step 1: Write the failing test**

Append to `Tests/SheetMusicTests/MSCXDiagnosticsTests.swift` (inside the existing `MSCXDiagnosticsTests` suite, after the two existing tests):

```swift
    @Test func diagnostic_fixture_resource_resolves() throws {
        let url = Bundle.module.url(
            forResource: "diagnostics-tremolo-unknown-subtype",
            withExtension: "mscx",
            subdirectory: "own",
        )
        #expect(url != nil)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MSCXDiagnosticsTests`
Expected: FAIL on the new test — `url` is nil (resource missing).

- [ ] **Step 3: Create the fixture LICENSE notice**

Create `Tests/SheetMusicTests/Resources/own/LICENSE`:

```
Test fixtures in this directory (Tests/SheetMusicTests/Resources/own/)
are hand-authored by the swift-sheet-music project under the MIT
license — identical to the terms in the repository root LICENSE.

They are distinct from the GPL-3.0 MuseScore-imported fixtures in the
parent directory (Tests/SheetMusicTests/Resources/), which retain
their original GPL-3.0 license per
Tests/SheetMusicTests/Resources/LICENSE.

Like all test fixtures in this repository, these files are confined to
the test target and are not bundled into any published library product.
```

- [ ] **Step 4: Create the .mscx fixture**

Create `Tests/SheetMusicTests/Resources/own/diagnostics-tremolo-unknown-subtype.mscx`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<museScore version="4.40">
  <Score>
    <Division>480</Division>
    <Part>
      <Staff id="1"/>
      <Instrument>
        <trackName>Test</trackName>
        <Channel>
          <program value="0"/>
        </Channel>
      </Instrument>
    </Part>
    <Staff id="1">
      <Measure>
        <voice>
          <TimeSig>
            <sigN>4</sigN>
            <sigD>4</sigD>
          </TimeSig>
          <Chord>
            <durationType>quarter</durationType>
            <TremoloSingleChord>
              <subtype>r128</subtype>
            </TremoloSingleChord>
            <Note>
              <pitch>60</pitch>
              <tpc>14</tpc>
            </Note>
          </Chord>
          <Rest>
            <durationType>half</durationType>
          </Rest>
          <Rest>
            <durationType>quarter</durationType>
          </Rest>
        </voice>
      </Measure>
    </Staff>
  </Score>
</museScore>
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter MSCXDiagnosticsTests`
Expected: PASS — including the new `diagnostic_fixture_resource_resolves`. The earlier two clean-file tests still PASS unchanged.

- [ ] **Step 6: Commit**

```bash
git add Tests/SheetMusicTests/Resources/own/LICENSE \
        Tests/SheetMusicTests/Resources/own/diagnostics-tremolo-unknown-subtype.mscx \
        Tests/SheetMusicTests/MSCXDiagnosticsTests.swift
git commit -m "test(mscx): add MIT-licensed diagnostic fixture (unknown tremolo subtype)"
```

---

### Task 6: Convert Tremolo decoder throws → diagnostic + drop

This is the central behavioural change. TDD here is meaningful: the test that loads the new fixture currently throws; after the change it returns a parsed score with one diagnostic and `chord.tremolo == nil`.

**Files:**
- Modify: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Tremolo.swift`
- Modify: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Chord.swift` (one line — call-site type)
- Modify: `Tests/SheetMusicTests/MSCXDiagnosticsTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/SheetMusicTests/MSCXDiagnosticsTests.swift` inside the existing suite:

```swift
    @Test func unknownTremoloSubtype_emitsDiagnostic_andDropsTremolo() throws {
        let url = Bundle.module.url(
            forResource: "diagnostics-tremolo-unknown-subtype",
            withExtension: "mscx",
            subdirectory: "own",
        )!
        let result = try MSCXParser.parseWithDiagnostics(contentsOf: url)

        // Score loaded.
        #expect(result.score.parts.count == 1)
        let chord = firstChord(in: result.score)
        #expect(chord != nil)
        // Tremolo was dropped — chord still present.
        #expect(chord?.tremolo == nil)

        // Exactly one diagnostic, with the stable code and the offending token.
        #expect(result.diagnostics.count == 1)
        let d = result.diagnostics.first
        #expect(d?.severity == .warning)
        #expect(d?.code == "mscx.tremolo.unknownSubtype")
        #expect(d?.message.contains("r128") == true)
    }

    @Test func plainParse_alsoLoadsFileWithUnknownTremolo() throws {
        // The non-diagnostics API must also load (it just discards warnings).
        let url = Bundle.module.url(
            forResource: "diagnostics-tremolo-unknown-subtype",
            withExtension: "mscx",
            subdirectory: "own",
        )!
        let score = try MSCXParser.parse(contentsOf: url)
        #expect(score.parts.count == 1)
        let chord = firstChord(in: score)
        #expect(chord?.tremolo == nil)
    }
```

Add this private helper at the bottom of the test file (outside the suite):

```swift
private func firstChord(in score: Score) -> Chord? {
    for part in score.parts {
        for staff in part.staves {
            for measure in staff.measures {
                for voice in measure.voices {
                    for el in voice.elements {
                        if case let .chord(c) = el, !c.notes.isEmpty {
                            return c
                        }
                    }
                }
            }
        }
    }
    return nil
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MSCXDiagnosticsTests`
Expected: FAIL — `unknownTremoloSubtype_emitsDiagnostic_andDropsTremolo` throws `SheetMusicError.malformedScore("Tremolo unknown <subtype> r128")` from the decoder. `plainParse_alsoLoadsFileWithUnknownTremolo` likewise throws.

- [ ] **Step 3: Update `Tremolo` decoder to return `Tremolo?` and emit diagnostics**

Replace the body of `extension Tremolo` in `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Tremolo.swift` so the public `decode(_:)` returns `Tremolo?`, missing-subtype and unknown-subtype paths emit a diagnostic and return `nil`. The full updated file:

```swift
import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Tremolo {
    /// First-pass MSCX decode of a `<Tremolo>` / `<TremoloSingleChord>` /
    /// `<TremoloTwoChord>` child of `<Chord>`. For the MS3-style
    /// `<Tremolo>` tag, `r8/r16/r32/r64` map to `.single` and
    /// `c8/c16/c32/c64` to `.between` (the pairing-validation second pass
    /// runs in `MSCXDecoder+Voice`). For MS4's tag-discriminated form,
    /// the tag name fixes the span and either prefix is accepted in
    /// `<subtype>`.
    ///
    /// Returns `nil` for non-fatal anomalies (missing or unknown
    /// `<subtype>`) after emitting a `ScoreDiagnostic`. The caller in
    /// `MSCXDecoder+Chord` treats `nil` the same as "no Tremolo child
    /// present".
    /// C++: `mu::engraving::TremoloDispatcher::read`,
    /// `TremoloSingleChord::read`, `TremoloTwoChord::read`.
    static func decode(_ node: XMLTreeNode) -> Tremolo? {
        guard let subtypeText = node.first("subtype")?.text else {
            mscxDecoderWarn(
                code: "mscx.tremolo.missingSubtype",
                message: "\(node.name) missing <subtype> — tremolo dropped",
            )
            return nil
        }
        let span: Span
        let subtype: Subtype
        switch node.name {
        case "TremoloSingleChord":
            guard let bars = parseBars(subtypeText, tagName: node.name) else {
                return nil
            }
            span = .single
            subtype = bars
        case "TremoloTwoChord":
            guard let bars = parseBars(subtypeText, tagName: node.name) else {
                return nil
            }
            span = .between
            subtype = bars
        default:
            guard let pair = parseSubtype(subtypeText) else {
                return nil
            }
            (subtype, span) = pair
        }
        let stroke = parseStrokeStyle(node.first("strokeStyle")?.text ?? "0")
        return Tremolo(subtype: subtype, span: span, strokeStyle: stroke)
    }

    private static func parseSubtype(
        _ text: String,
    ) -> (Subtype, Span)? {
        switch text {
        case "r8": return (.r8, .single)
        case "r16": return (.r16, .single)
        case "r32": return (.r32, .single)
        case "r64": return (.r64, .single)
        case "c8": return (.r8, .between)
        case "c16": return (.r16, .between)
        case "c32": return (.r32, .between)
        case "c64": return (.r64, .between)
        default:
            mscxDecoderWarn(
                code: "mscx.tremolo.unknownSubtype",
                message: "Tremolo unknown <subtype> \(text) — tremolo dropped",
            )
            return nil
        }
    }

    /// MS4 form: the tag name (`TremoloSingleChord` / `TremoloTwoChord`)
    /// already pins the span, so the subtype string only needs to
    /// resolve the bar count. Either the `r*` or `c*` prefix is
    /// accepted defensively since both MS4 readers in upstream
    /// MuseScore route through the same TConv-driven token table.
    private static func parseBars(
        _ text: String,
        tagName: String,
    ) -> Subtype? {
        switch text {
        case "r8", "c8": return .r8
        case "r16", "c16": return .r16
        case "r32", "c32": return .r32
        case "r64", "c64": return .r64
        default:
            mscxDecoderWarn(
                code: "mscx.tremolo.unknownSubtype",
                message: "\(tagName) unknown <subtype> \(text) — tremolo dropped",
            )
            return nil
        }
    }

    private static func parseStrokeStyle(_ text: String) -> StrokeStyle {
        switch text {
        case "1": return .traditional
        case "2": return .z
        default: return .default
        }
    }
}
```

- [ ] **Step 4: Update the Chord decoder call site**

In `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Chord.swift`, change line 63 from:

```swift
        let tremolo = try tremoloNode.map(Tremolo.decode)
```

to:

```swift
        let tremolo = tremoloNode.flatMap(Tremolo.decode)
```

Rationale: `Tremolo.decode` no longer throws, and now returns `Tremolo?`. `Optional.flatMap` unwraps the outer optional so the assignment stays `Tremolo?`. No other change to this file.

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter MSCXDiagnosticsTests`
Expected: PASS — including the two new tests added in Step 1, plus all prior tests in this suite.

- [ ] **Step 6: Sanity-run the existing Tremolo test suite**

Run: `swift test --filter "TremoloMSCXDecode|TremoloMSCXEncode|TremoloSegments|TremoloVoice|TremoloModel|TremoloTie"`

Expected: One failure — `TremoloMSCXDecodeFirstPassTests::unknown_subtype_throws` (currently expects throws for `r128`; will be fixed in Task 7). All other Tremolo tests PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Tremolo.swift \
        Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Chord.swift \
        Tests/SheetMusicTests/MSCXDiagnosticsTests.swift
git commit -m "feat(mscx): convert Tremolo decoder throws to diagnostics

Tremolo.decode now returns Tremolo? — missing or unknown <subtype>
emits a ScoreDiagnostic (mscx.tremolo.missingSubtype /
mscx.tremolo.unknownSubtype) and drops the tremolo. The chord still
parses; its notes and duration are unaffected. The non-diagnostics
parse(...) API shares the same path and also loads such files."
```

---

### Task 7: Rewrite `unknown_subtype_throws` test to assert diagnostic

**Files:**
- Modify: `Tests/SheetMusicTests/TremoloMSCXDecodeTests.swift`

- [ ] **Step 1: Locate the existing test**

The test is in `Tests/SheetMusicTests/TremoloMSCXDecodeTests.swift` around line 79 (verified during spec authoring). It currently reads:

```swift
    @Test func unknown_subtype_throws() throws {
        let xml = """
        <Chord>
            <durationType>quarter</durationType>
            <Tremolo>
                <subtype>r128</subtype>
            </Tremolo>
            <Note><pitch>60</pitch><tpc>14</tpc></Note>
        </Chord>
        """
        #expect(throws: SheetMusicError.self) {
            _ = try parseChord(xml)
        }
    }
```

- [ ] **Step 2: Replace with the diagnostic-asserting version**

Replace the entire `unknown_subtype_throws()` test with:

```swift
    @Test func unknown_subtype_emits_diagnostic_and_drops_tremolo() throws {
        let xml = """
        <Chord>
            <durationType>quarter</durationType>
            <Tremolo>
                <subtype>r128</subtype>
            </Tremolo>
            <Note><pitch>60</pitch><tpc>14</tpc></Note>
        </Chord>
        """
        let collector = MSCXDiagnosticCollector()
        let chord = try MSCXParserContext.$collector.withValue(collector) {
            try parseChord(xml)
        }
        #expect(chord.tremolo == nil)
        #expect(collector.entries.count == 1)
        #expect(collector.entries.first?.code == "mscx.tremolo.unknownSubtype")
    }
```

> `withValue` returns whatever the operation returns. The operation now throws (instead of `try?`) so a real decode failure surfaces as a test error rather than silently giving `nil`. `chord` is therefore plain `Chord`.

- [ ] **Step 3: Run test to verify it passes**

Run: `swift test --filter TremoloMSCXDecodeFirstPassTests`
Expected: PASS — all tests in the suite, including the renamed one.

- [ ] **Step 4: Commit**

```bash
git add Tests/SheetMusicTests/TremoloMSCXDecodeTests.swift
git commit -m "test(mscx): rewrite unknown_subtype_throws to assert diagnostic"
```

---

### Task 8: Reroute existing `mscxDecoderLogger.warning(...)` calls through `mscxDecoderWarn`

The spec identifies three sites: one in Breath, two in Score. Behaviour change: each warning that previously only went to `os_log` now also appears in `parseWithDiagnostics` output. Console output remains identical.

**Files:**
- Modify: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Breath.swift`
- Modify: `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Score.swift`
- Modify: `Tests/SheetMusicTests/MSCXDiagnosticsTests.swift` (add coverage)

- [ ] **Step 1: Write the failing test**

Append to `Tests/SheetMusicTests/MSCXDiagnosticsTests.swift` inside the suite:

```swift
    @Test func breath_unknownSubtype_emitsDiagnostic() throws {
        // A direct-decode probe: feed a `<Breath>` with an unknown
        // subtype into the decoder under an active collector.
        let xml = """
        <Breath>
          <subtype>not-a-real-breath</subtype>
        </Breath>
        """
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        let collector = MSCXDiagnosticCollector()
        let breath = MSCXParserContext.$collector.withValue(collector) {
            Breath.decodeMSCX(node)
        }
        // Decoder still returns a fallback breath.
        _ = breath
        #expect(collector.entries.count == 1)
        #expect(collector.entries.first?.code == "mscx.breath.unknownSubtype")
    }
```

> `XMLTreeParser.parse(_:)` is already imported transitively via `@testable import SheetMusicMSCX`; add `@testable import SheetMusicXMLTools` at the top of `MSCXDiagnosticsTests.swift` if `XMLTreeParser` isn't visible.

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MSCXDiagnosticsTests`
Expected: FAIL on the new `breath_unknownSubtype_emitsDiagnostic` — the Breath decoder still calls `mscxDecoderLogger.warning(...)` directly, so the collector stays empty.

- [ ] **Step 3: Update `MSCXDecoder+Breath.swift`**

In `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Breath.swift`, replace the `else` branch (currently the `#if canImport(os)` block at lines 19-30) with:

```swift
        } else {
            mscxDecoderWarn(
                code: "mscx.breath.unknownSubtype",
                message: "unknown <Breath><subtype>: \(rawSubtype) — falling back to breathMarkComma",
            )
            kind = .breathMark(.comma)
        }
```

Drop the surrounding `#if canImport(os)` since `mscxDecoderWarn` handles the platform gate internally.

- [ ] **Step 4: Update `MSCXDecoder+Score.swift` — two sites**

In `Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Score.swift`, replace the two `mscxDecoderLogger.warning(...)` blocks inside `detectVersion(...)`:

**Site A** (currently lines 133-144, inside the `majorInt <= 2` branch):

```swift
            if majorInt <= 2 {
                let programVersion = scoreNode.first("programVersion")?.text ?? "unknown"
                mscxDecoderWarn(
                    code: "mscx.score.museScoreVersion2",
                    message: """
                    detected MuseScore 2 file (museScore version=\"\(versionAttr)\", \
                    programVersion=\(programVersion)); parsing through the MS3/MS4-shaped \
                    reader — some MS2-only fields will be skipped silently.
                    """,
                )
                return .v2
            }
```

**Site B** (currently lines 150-161, inside the `programVersion.hasPrefix("2.")` branch):

```swift
            if programVersion.hasPrefix("2.") {
                mscxDecoderWarn(
                    code: "mscx.score.museScoreVersion2",
                    message: """
                    detected MuseScore 2 file via programVersion \(programVersion); \
                    parsing through the MS3/MS4-shaped reader — some MS2-only fields \
                    will be skipped silently.
                    """,
                )
                return .v2
            }
```

In both cases, drop the surrounding `#if canImport(os)` blocks. `mscxDecoderWarn` handles `os` availability internally.

> Sanity check: these are the only two `mscxDecoderLogger.warning(...)` call sites in `MSCXDecoder+Score.swift`. The `let mscxDecoderLogger = Logger(...)` declaration at lines 8-13 stays — the helper still references it.

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter MSCXDiagnosticsTests`
Expected: PASS — including `breath_unknownSubtype_emitsDiagnostic`.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Breath.swift \
        Sources/SheetMusicMSCX/Decoders/MSCXDecoder+Score.swift \
        Tests/SheetMusicTests/MSCXDiagnosticsTests.swift
git commit -m "feat(mscx): route existing logger warnings through mscxDecoderWarn

Breath / Score decoder warnings now appear in parseWithDiagnostics
output as well as os_log. Codes: mscx.breath.unknownSubtype,
mscx.score.museScoreVersion2."
```

---

### Task 9: Add the remaining diagnostic test cases

Spec section 4.2 listed six tests. After tasks 4–8, the file contains: `cleanFile_yieldsEmptyDiagnostics_mscx`, `cleanFile_yieldsEmptyDiagnostics_mscz`, `diagnostic_fixture_resource_resolves`, `unknownTremoloSubtype_emitsDiagnostic_andDropsTremolo`, `plainParse_alsoLoadsFileWithUnknownTremolo`, `breath_unknownSubtype_emitsDiagnostic`. The two remaining from the spec list — `missingTremoloSubtype_emitsDiagnostic_andDropsTremolo` and `diagnosticHasStableCode` — go in this task.

**Files:**
- Modify: `Tests/SheetMusicTests/MSCXDiagnosticsTests.swift`

- [ ] **Step 1: Add `missingTremoloSubtype_emitsDiagnostic_andDropsTremolo`**

Append to the suite:

```swift
    @Test func missingTremoloSubtype_emitsDiagnostic_andDropsTremolo() throws {
        // Construct the XML in-line by stripping the <subtype> child from
        // the bundled fixture — keeps the assertion targeted on the
        // missing-subtype path.
        let url = Bundle.module.url(
            forResource: "diagnostics-tremolo-unknown-subtype",
            withExtension: "mscx",
            subdirectory: "own",
        )!
        var xml = try String(contentsOf: url, encoding: .utf8)
        xml = xml.replacingOccurrences(
            of: "<subtype>r128</subtype>",
            with: "",
        )
        let result = try MSCXParser.parseWithDiagnostics(Data(xml.utf8))
        let chord = firstChord(in: result.score)
        #expect(chord?.tremolo == nil)
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics.first?.code == "mscx.tremolo.missingSubtype")
    }
```

- [ ] **Step 2: Add `diagnosticHasStableCode`**

Append to the suite:

```swift
    @Test func diagnosticHasStableCode() throws {
        // The dotted-namespace contract is a public guarantee — if any
        // emitter drifts from it, callers' downstream filters break
        // silently. Verify a few known codes round-trip through a real
        // parse.
        let url = Bundle.module.url(
            forResource: "diagnostics-tremolo-unknown-subtype",
            withExtension: "mscx",
            subdirectory: "own",
        )!
        let result = try MSCXParser.parseWithDiagnostics(contentsOf: url)
        for d in result.diagnostics {
            #expect(d.code.hasPrefix("mscx."))
            #expect(d.code.split(separator: ".").count >= 3)
        }
    }
```

- [ ] **Step 3: Run all diagnostic tests to verify they pass**

Run: `swift test --filter MSCXDiagnosticsTests`
Expected: PASS — 8 tests total.

- [ ] **Step 4: Commit**

```bash
git add Tests/SheetMusicTests/MSCXDiagnosticsTests.swift
git commit -m "test(mscx): cover missing-subtype path and stable-code contract"
```

---

### Task 10: Document the categorisation policy in `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Locate the existing bullet**

Open `CLAUDE.md` and find the bullet under `## Conventions`:

```
- **Permissive parser.** Unknown XML elements inside a `<voice>` are
  silently skipped (see `MSCXDecoder+Voice.swift`). Required elements
  that genuinely can't be defaulted throw `SheetMusicError.malformedScore`.
```

- [ ] **Step 2: Replace with the extended policy**

Replace that bullet with:

```
- **Permissive parser.** Unknown XML elements inside a `<voice>` are
  silently skipped (see `MSCXDecoder+Voice.swift`). For known elements
  with unknown / missing values, MSCX decoders use a three-way policy:
  - **Structural** (pitch, voice structure, time signature, division):
    throw `SheetMusicError.malformedScore` — the score can't be loaded
    coherently.
  - **Embellishment** (tremolo subtype, articulation kind, ornament
    subtype, fermata / breath style, hairpin shape, glissando style):
    drop the element and emit a `ScoreDiagnostic` via `mscxDecoderWarn`.
    The score still loads; the decoration is silently absent. Surface
    via `MSCXParser.parseWithDiagnostics(...)` /
    `MSCZReader.parseWithDiagnostics(...)`.
  - **Cosmetic** (color, offset, font, stroke style): silent default
    to the model's neutral value.
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document Structural / Embellishment / Cosmetic decoder policy"
```

---

### Task 11: Full verification + linting

**Files:** (no source changes — verification only)

- [ ] **Step 1: Run the entire test suite**

Run: `swift test`
Expected: 100% green. Pay attention to:
- `MSCXDiagnosticsTests` — all 8 cases pass.
- `MSCXDiagnosticCollectorTests` / `MSCXDecoderWarnTests` / `MSCXParseResultTests` — all pass.
- `ScoreDiagnosticTests` — all 3 pass.
- `TremoloMSCXDecodeFirstPassTests::unknown_subtype_emits_diagnostic_and_drops_tremolo` — passes.
- Existing `MidiExportTests` (12 MuseScore-equivalence cases) — unchanged, all pass.

If any test fails that is not in the new code, stop and investigate — that's a regression in the existing decoder path, not the intended scope.

- [ ] **Step 2: Run SwiftLint**

Run: `swiftlint --quiet Sources Tests`
Expected: zero warnings, zero errors. If SwiftLint flags anything in the new files (line length, file length, etc.), fix in place and re-run.

- [ ] **Step 3: Quick Android cross-compile smoke check**

Verify the new code paths don't break Android cross-compilation. `mscxDecoderWarn` already gates `os` behind `#if canImport(os)`; Android lacks `os` so the helper falls through to the collector path only.

```bash
export TOOLCHAINS=org.swift.632202605101a
SWIFT_SHEET_MUSIC_ANDROID=1 swift build \
    --swift-sdk aarch64-unknown-linux-android28
unset TOOLCHAINS
```

Expected: Build complete. If `mscxDecoderLogger` references from `MSCXDecoder+Score.swift` break the Android build, the `let mscxDecoderLogger = ...` declaration is already inside `#if canImport(os)` — confirm the new `mscxDecoderWarn` references to it from `MSCXDecoderWarn.swift` are also inside `#if canImport(os)`. (Step 4 of Task 3 already had this gate; this step is a sanity check that it holds.)

- [ ] **Step 4: Final commit (only if anything was tweaked in steps 1-3)**

If verification surfaced anything that needed a small fix, commit it:

```bash
git add -A
git commit -m "chore: post-verification cleanup"
```

Otherwise, skip — nothing to commit.

- [ ] **Step 5: Review the branch's commit history**

Run: `git log --oneline main..HEAD`
Expected (approximately, in this order):
```
chore: post-verification cleanup            (optional)
docs: document Structural / Embellishment / Cosmetic decoder policy
test(mscx): cover missing-subtype path and stable-code contract
feat(mscx): route existing logger warnings through mscxDecoderWarn
test(mscx): rewrite unknown_subtype_throws to assert diagnostic
feat(mscx): convert Tremolo decoder throws to diagnostics
test(mscx): add MIT-licensed diagnostic fixture (unknown tremolo subtype)
feat(mscx): add parseWithDiagnostics public API
feat(mscx): add MSCXParseResult and mscxDecoderWarn helper
feat(mscx): add MSCXDiagnosticCollector + MSCXParserContext
feat(core): add ScoreDiagnostic value type
spec: MSCX parser diagnostics
```

If the history matches and tests + lint are green, the plan is complete.

---

## Self-Review Notes

**Spec coverage check:** Each spec section maps to tasks:
- Architecture / `ScoreDiagnostic` → Task 1
- `MSCXParseResult` + collector + TaskLocal → Tasks 2 + 3
- Public API → Task 4
- `mscxDecoderWarn` helper → Task 3
- Categorisation policy + Tremolo conversions → Tasks 6 + 10
- Existing logger sites → Task 8
- Test fixture + tests → Tasks 5 + 9
- Existing test rewrite → Task 7
- Acceptance criteria 1-6 → Task 11 + Tasks 4-10

**Type-consistency check:**
- `ScoreDiagnostic` fields: `severity, code, message, location` — used consistently across all tasks ✓
- `MSCXParseResult` fields: `score, diagnostics` — used in Tasks 3-9 ✓
- `MSCXDiagnosticCollector.warn(code:message:location:)` / `.info(...)` — signature stable across tasks ✓
- `mscxDecoderWarn(code:message:location:)` — same signature ✓
- `Tremolo.decode(_:)` returns `Tremolo?` (Task 6) — consumed via `flatMap` in Chord (Task 6, step 4) ✓
- Stable codes (`mscx.tremolo.unknownSubtype`, `mscx.tremolo.missingSubtype`, `mscx.breath.unknownSubtype`, `mscx.score.museScoreVersion2`) — appear in matching test assertions ✓
