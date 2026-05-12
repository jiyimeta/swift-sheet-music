# Audio File Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an offline audio-file export API to `SheetMusicAudio` (`PlaybackEngine.exportAudioFile(...)`) supporting WAV, AIFF, M4A, and MP3, with codec-specific options expressed as associated values on a typed `AudioFileFormat` enum. The exported audio reflects the live engine state (mixer, metronome, program changes, rate).

**Architecture:** Add a new `Export/` sub-tree under `Sources/SheetMusicAudio/`. Public surface: `AudioFileFormat`, `PCMOptions`, `CompressedOptions`, `AudioChannelCount`, `PCMBitDepth`, `AudioExportRange`, `AudioExportError`, and `PlaybackEngine.exportAudioFile(...)`. Internals: an `AudioFileExporter` actor that drives `AVAudioEngine.enableManualRenderingMode(.offline, ...)`, plus a small `AudioExportWriter` protocol with PCM (`AVAudioFile` for WAV/AIFF), compressed (`AVAudioFile` with AAC settings for M4A), and MP3 (`AVAssetWriter`, iOS 17+/macOS 14+) back-ends.

**Tech Stack:** Swift Package Manager, Swift 6.2, Swift Testing (`@Test`, `#expect`), `AVFoundation` (AVAudioEngine manual rendering / AVAudioFile / AVAssetWriter).

**Spec:** `docs/superpowers/specs/2026-05-12-audio-file-export-design.md`

---

## File Structure

**Create:**

- `Sources/SheetMusicAudio/Export/AudioFileFormat.swift` — `AudioFileFormat` enum, `PCMBitDepth`, `AudioChannelCount`, `PCMOptions`, `CompressedOptions`.
- `Sources/SheetMusicAudio/Export/AudioExportRange.swift` — `AudioExportRange` enum.
- `Sources/SheetMusicAudio/Export/AudioExportError.swift` — `AudioExportError` enum.
- `Sources/SheetMusicAudio/Export/AudioExportWriter.swift` — file-private `AudioExportWriter` protocol + `PCMAudioExportWriter` + `CompressedAudioExportWriter` (M4A) + `MP3AudioExportWriter` (gated).
- `Sources/SheetMusicAudio/Export/AudioFileExporter.swift` — `AudioFileExporter` actor; offline-render loop.
- `Sources/SheetMusicAudio/PlaybackEngine+Export.swift` — `PlaybackEngine.exportAudioFile(...)` public method + state-machine guards.
- `Tests/SheetMusicTests/AudioFileFormatTests.swift` — option-struct defaults, sendability spot-checks.
- `Tests/SheetMusicTests/AudioExportRangeTests.swift` — range enum sanity.
- `Tests/SheetMusicTests/AudioExportErrorTests.swift` — error enum equality.
- `Tests/SheetMusicTests/AudioFileExporterTests.swift` — end-to-end smoke tests (WAV/AIFF/M4A, optional MP3), range narrowing, cancellation, error paths.

**Modify:**

- `Sources/SheetMusicAudio/PlaybackEngine.swift` — add `.exporting` case to `PlaybackState`; add `guard state != .exporting else { return }` on the public mutation methods (`play`, `pause`, `stop`, `seek`, `setRate`, the two `setLoop` overloads, `clearLoop`, `skip`, `clearCursor`, `playPreview`). Expose an internal setter (`func setStateForExport(_ newState: PlaybackState)`) so the exporter can flip state without breaking the `private(set)` invariant.
- `Sources/SheetMusicAudio/README.md` (create if missing) — short usage doc including the SwiftUI `FormatTag` Picker pattern.
- `Example/SheetMusicExample/project.yml` — no source changes needed (the directory is rescanned), but list anyway so the engineer remembers to regenerate after adding files.
- `Example/SheetMusicExample/Audio/AudioExportSheet.swift` (create) — SwiftUI sheet with format picker, options form, save button, progress bar, cancel button. Used by both iOS and macOS hosts.
- `Example/SheetMusicExample/iOS/ContentView_iOS.swift` (or the relevant root view; engineer should locate the toolbar item) — add a toolbar item to present `AudioExportSheet`.
- `Example/SheetMusicExample/macOS/ContentView_macOS.swift` — same.
- `CLAUDE.md` — bring the Library layout / File layout sections in line with the current `Package.swift`, add the Export sub-tree, add the "M4A is `AVAudioFile`, MP3 is `AVAssetWriter`" pitfall.

**Not modified:**

- `Package.swift` — no new product, no new target, no new dependency. Platform minimums stay at iOS 16 / macOS 13 / tvOS 16 / watchOS 9.

---

## Build / test commands the engineer will use

```bash
# Fast iteration: package tests only
swift test --filter AudioFileFormatTests
swift test --filter AudioExportRangeTests
swift test --filter AudioExportErrorTests
swift test --filter AudioFileExporterTests

# Full package
swift test

# Lint
swiftlint --quiet Sources Tests

# Example app — iOS Simulator (after adding new files to project.yml-driven sources)
cd Example && xcodegen generate
xcodebuild -project Example/SheetMusicExample.xcodeproj \
           -scheme SheetMusicExample \
           -destination 'platform=iOS Simulator,name=iPhone 17' build

# Example app — macOS (the path the user uses for visual verification)
xcodebuild -project Example/SheetMusicExample.xcodeproj \
           -scheme SheetMusicExampleMac \
           build
```

---

## Task 1: `AudioFileFormat` + options structs

**Files:**
- Create: `Sources/SheetMusicAudio/Export/AudioFileFormat.swift`
- Test: `Tests/SheetMusicTests/AudioFileFormatTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/AudioFileFormatTests.swift`:

```swift
@testable import SheetMusicAudio
import Testing

@Suite("AudioFileFormat")
struct AudioFileFormatTests {
    @Test("PCMOptions has CD-quality defaults")
    func pcmDefaults() {
        let opts = PCMOptions()
        #expect(opts.sampleRate == 44_100)
        #expect(opts.bitDepth == .int16)
        #expect(opts.channels == .stereo)
    }

    @Test("CompressedOptions has 192 kbps stereo defaults")
    func compressedDefaults() {
        let opts = CompressedOptions()
        #expect(opts.sampleRate == 44_100)
        #expect(opts.bitRate == 192_000)
        #expect(opts.channels == .stereo)
    }

    @Test("Bare-case construction uses default-initialised payload")
    func bareCaseUsesDefaults() {
        let wav = AudioFileFormat.wav()
        if case let .wav(opts) = wav {
            #expect(opts.sampleRate == 44_100)
            #expect(opts.bitDepth == .int16)
        } else {
            Issue.record("Expected .wav case")
        }
    }

    @Test("Mp3 case is constructable on all platforms (runtime-gated elsewhere)")
    func mp3CaseExists() {
        _ = AudioFileFormat.mp3(CompressedOptions(bitRate: 128_000))
    }

    @Test("AudioChannelCount raw values match channel counts")
    func channelCountRaws() {
        #expect(AudioChannelCount.mono.rawValue == 1)
        #expect(AudioChannelCount.stereo.rawValue == 2)
    }

    @Test("PCMBitDepth includes float32")
    func bitDepthIncludesFloat() {
        #expect(PCMBitDepth.allCases.contains(.float32))
    }
}
```

- [ ] **Step 2: Run the test, confirm it fails**

```bash
swift test --filter AudioFileFormatTests
```

Expected: compile failure — `cannot find 'AudioFileFormat' in scope`.

- [ ] **Step 3: Implement the types**

Create `Sources/SheetMusicAudio/Export/AudioFileFormat.swift`:

```swift
import Foundation

/// Container + codec selection for audio file export.
///
/// Each case carries its codec-specific options. Bare construction
/// — `.wav()`, `.aiff()`, `.m4a()`, `.mp3()` — uses the default
/// options struct. Bind a SwiftUI `Picker` to a separate tag enum
/// (see `SheetMusicAudio` README) since associated-value enums
/// don't play well with `Picker`.
public enum AudioFileFormat: Sendable {
    case wav(PCMOptions = .init())
    case aiff(PCMOptions = .init())
    case m4a(CompressedOptions = .init())
    case mp3(CompressedOptions = .init())
}

/// Sample resolution for PCM formats (WAV / AIFF).
public enum PCMBitDepth: Sendable, CaseIterable {
    case int16, int24, int32, float32
}

/// 1 = mono, 2 = stereo. Surround is out of scope.
public enum AudioChannelCount: Int, Sendable, CaseIterable {
    case mono = 1
    case stereo = 2
}

public struct PCMOptions: Sendable, Equatable {
    public var sampleRate: Double
    public var bitDepth: PCMBitDepth
    public var channels: AudioChannelCount

    public init(
        sampleRate: Double = 44_100,
        bitDepth: PCMBitDepth = .int16,
        channels: AudioChannelCount = .stereo
    ) {
        self.sampleRate = sampleRate
        self.bitDepth = bitDepth
        self.channels = channels
    }
}

public struct CompressedOptions: Sendable, Equatable {
    public var sampleRate: Double
    /// Bits per second. `192_000` is "transparent" AAC; `128_000`
    /// is a common smaller-file default.
    public var bitRate: Int
    public var channels: AudioChannelCount

    public init(
        sampleRate: Double = 44_100,
        bitRate: Int = 192_000,
        channels: AudioChannelCount = .stereo
    ) {
        self.sampleRate = sampleRate
        self.bitRate = bitRate
        self.channels = channels
    }
}
```

- [ ] **Step 4: Run tests, confirm they pass**

```bash
swift test --filter AudioFileFormatTests
```

Expected: PASS (6 tests).

- [ ] **Step 5: Lint**

```bash
swiftlint --quiet Sources/SheetMusicAudio/Export Tests/SheetMusicTests/AudioFileFormatTests.swift
```

Expected: no output.

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicAudio/Export/AudioFileFormat.swift \
        Tests/SheetMusicTests/AudioFileFormatTests.swift
git commit -m "audio: add AudioFileFormat + PCM/Compressed options"
```

---

## Task 2: `AudioExportRange`

**Files:**
- Create: `Sources/SheetMusicAudio/Export/AudioExportRange.swift`
- Test: `Tests/SheetMusicTests/AudioExportRangeTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/AudioExportRangeTests.swift`:

```swift
@testable import SheetMusicAudio
import SheetMusicCore
import Testing

@Suite("AudioExportRange")
struct AudioExportRangeTests {
    @Test(".full is the default-equivalent case")
    func fullExists() {
        let r: AudioExportRange = .full
        if case .full = r { /* ok */ } else { Issue.record("Expected .full") }
    }

    @Test(".currentLoop is constructable")
    func currentLoopExists() {
        let r: AudioExportRange = .currentLoop
        if case .currentLoop = r { /* ok */ } else { Issue.record("Expected .currentLoop") }
    }

    @Test(".region carries two cursors")
    func regionCarriesCursors() {
        let start = ScoreCursor(staffIndex: 0, measureIndex: 0, voiceIndex: 0, elementIndex: 0)
        let end   = ScoreCursor(staffIndex: 0, measureIndex: 1, voiceIndex: 0, elementIndex: 0)
        let r: AudioExportRange = .region(from: start, to: end)
        if case let .region(s, e) = r {
            #expect(s == start)
            #expect(e == end)
        } else {
            Issue.record("Expected .region")
        }
    }
}
```

(Note: `ScoreCursor` shape is defined in `SheetMusicCore`. If the
default initialiser differs, look at
`Sources/SheetMusicCore/Score/ScoreCursor.swift` and use whatever
constructor exists.)

- [ ] **Step 2: Run the test, confirm it fails**

```bash
swift test --filter AudioExportRangeTests
```

Expected: compile failure — `cannot find 'AudioExportRange'`.

- [ ] **Step 3: Implement the type**

Create `Sources/SheetMusicAudio/Export/AudioExportRange.swift`:

```swift
import SheetMusicCore

/// What region of the score to export to audio.
///
/// `.full`           — entire score (default).
/// `.currentLoop`    — `PlaybackEngine.loopRange` if set, else falls
///                     back to `.full`.
/// `.region`         — half-open `[from, to)` cursor range.
/// `.regionThroughEnd` — like `.region`, but extends through the
///                     full duration of `last` so its trailing
///                     ring is included.
public enum AudioExportRange: Sendable {
    case full
    case currentLoop
    case region(from: ScoreCursor, to: ScoreCursor)
    case regionThroughEnd(from: ScoreCursor, last: ScoreItemID)
}
```

- [ ] **Step 4: Run tests, confirm they pass**

```bash
swift test --filter AudioExportRangeTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicAudio/Export/AudioExportRange.swift \
        Tests/SheetMusicTests/AudioExportRangeTests.swift
git commit -m "audio: add AudioExportRange enum"
```

---

## Task 3: `AudioExportError`

**Files:**
- Create: `Sources/SheetMusicAudio/Export/AudioExportError.swift`
- Test: `Tests/SheetMusicTests/AudioExportErrorTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/AudioExportErrorTests.swift`:

```swift
@testable import SheetMusicAudio
import Testing

@Suite("AudioExportError")
struct AudioExportErrorTests {
    @Test("Cases are Equatable")
    func equatable() {
        #expect(AudioExportError.noScorePrepared == .noScorePrepared)
        #expect(AudioExportError.cancelled == .cancelled)
        #expect(AudioExportError.engineSetupFailed(underlying: "x")
                == .engineSetupFailed(underlying: "x"))
        #expect(AudioExportError.engineSetupFailed(underlying: "x")
                != .engineSetupFailed(underlying: "y"))
    }

    @Test("formatUnsupportedOnThisOS carries the format")
    func formatUnsupportedCarriesFormat() {
        let err: AudioExportError = .formatUnsupportedOnThisOS(.mp3())
        if case let .formatUnsupportedOnThisOS(fmt) = err {
            if case .mp3 = fmt { /* ok */ } else { Issue.record("wrong fmt") }
        } else {
            Issue.record("wrong case")
        }
    }
}
```

- [ ] **Step 2: Run the test, confirm it fails**

```bash
swift test --filter AudioExportErrorTests
```

Expected: compile failure.

- [ ] **Step 3: Implement the type**

Create `Sources/SheetMusicAudio/Export/AudioExportError.swift`:

```swift
import Foundation

/// Errors thrown by `PlaybackEngine.exportAudioFile(...)`.
///
/// `underlying: String` rather than `Error` so this stays
/// `Equatable` / `Sendable` cheaply. We render the description of
/// the original `NSError` at throw time.
public enum AudioExportError: Error, Sendable, Equatable {
    /// `prepare(score:)` has not been called for the score passed
    /// to `exportAudioFile(...)`.
    case noScorePrepared

    /// One or both cursors in `.region(...)` / `.regionThroughEnd(...)`
    /// don't resolve into the prepared score's `PlaybackTimeline`.
    case rangeNotInTimeline

    /// Format requires an OS newer than the running one (MP3 needs
    /// iOS 17 / macOS 14 / tvOS 17 / watchOS 10).
    case formatUnsupportedOnThisOS(AudioFileFormat)

    /// `AVAudioEngine.enableManualRenderingMode(...)` or
    /// `engine.start()` threw.
    case engineSetupFailed(underlying: String)

    /// `AVAudioFile` / `AVAssetWriter` write or close threw.
    case fileWriteFailed(underlying: String)

    /// `Task.checkCancellation()` fired during the render loop.
    case cancelled
}
```

- [ ] **Step 4: Run tests, confirm they pass**

```bash
swift test --filter AudioExportErrorTests
```

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicAudio/Export/AudioExportError.swift \
        Tests/SheetMusicTests/AudioExportErrorTests.swift
git commit -m "audio: add AudioExportError enum"
```

---

## Task 4: Add `.exporting` to `PlaybackState`, expose internal setter

**Files:**
- Modify: `Sources/SheetMusicAudio/PlaybackEngine.swift`
- Test: `Tests/SheetMusicTests/AudioFileExporterTests.swift` (we'll create the file in this task and add a state-equality test; integration tests for the export pipeline land in Task 8).

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/AudioFileExporterTests.swift` with the
state-case smoke test only for now (more tests are added in Task 8):

```swift
@testable import SheetMusicAudio
import Testing

@Suite("PlaybackState .exporting")
struct PlaybackStateExportingCaseTests {
    @Test(".exporting is a distinct case")
    func exportingIsDistinct() {
        let s: PlaybackState = .exporting
        #expect(s == .exporting)
        #expect(s != .playing)
        #expect(s != .paused)
        #expect(s != .stopped)
    }
}
```

- [ ] **Step 2: Run, confirm fail**

```bash
swift test --filter PlaybackStateExportingCaseTests
```

Expected: compile failure — `'exporting' is not a member of 'PlaybackState'`.

- [ ] **Step 3: Add the case + internal setter**

Edit `Sources/SheetMusicAudio/PlaybackEngine.swift`:

Change the enum:

```swift
public enum PlaybackState: Sendable, Equatable {
    case stopped, playing, paused, exporting
}
```

Add inside `PlaybackEngine` (near the other `// MARK: Internal accessors for `PlaybackEngine+Mixer`` block, around line 134):

```swift
// MARK: Internal accessors for `PlaybackEngine+Export`

func setStateForExport(_ newState: PlaybackState) {
    state = newState
}
```

Add guards at the top of these public methods (line numbers
approximate; reference the post-edit file):

- `setRate(_:)` — guard, return.
- `play(from:in:)` — guard, return.
- `seek(to:)` — guard, return.
- `setLoop(from:to:)` — guard, return.
- `setLoop(from:throughEndOf:)` — guard, return.
- `clearLoop()` — guard, return.
- `skip(by:)` — guard, return.
- `pause()` — guard, return.
- `stop()` — guard, return.
- `clearCursor()` — guard, return.
- `playPreview(noteID:in:duration:velocity:)` — guard, return.

Pattern (apply at the top of each method body):

```swift
guard state != .exporting else { return }
```

For `prepare(score:)`, **do not** add the guard — `prepare` already
calls `stop()`. Instead, add at the top:

```swift
// If an export is in flight the caller is expected to cancel its
// `Task` before calling `prepare(score:)` on a different score.
// We don't cancel for them — but we do refuse to tear down the
// samplers under the exporter's feet.
if state == .exporting {
    return
}
```

(That early-return is intentionally not `throw`; `prepare` has its
own `throws` for engine setup failures, and we don't want to add a
new public error case for this edge.)

- [ ] **Step 4: Run, confirm pass**

```bash
swift test --filter PlaybackStateExportingCaseTests
swift test --filter PlaybackTimeline  # smoke: existing tests still green
```

Expected: PASS on both.

- [ ] **Step 5: Lint**

```bash
swiftlint --quiet Sources/SheetMusicAudio/PlaybackEngine.swift
```

Expected: no new warnings. (`PlaybackEngine.swift` already
`swiftlint:disable file_length` at the top.)

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicAudio/PlaybackEngine.swift \
        Tests/SheetMusicTests/AudioFileExporterTests.swift
git commit -m "audio: add PlaybackState.exporting + per-method guards"
```

---

## Task 5: `AudioExportWriter` protocol + PCM writer (WAV / AIFF)

**Files:**
- Create: `Sources/SheetMusicAudio/Export/AudioExportWriter.swift`
- Test: extend `Tests/SheetMusicTests/AudioFileExporterTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/SheetMusicTests/AudioFileExporterTests.swift`:

```swift
import AVFoundation

@Suite("PCMAudioExportWriter")
struct PCMAudioExportWriterTests {
    /// Writing one buffer of silence to a .wav and reading it back
    /// yields the expected sample rate / channels / frame count.
    @Test("WAV writer round-trip")
    func wavRoundTrip() async throws {
        let url = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("smwriter-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let options = PCMOptions(sampleRate: 22_050, bitDepth: .int16, channels: .mono)
        let writer = try PCMAudioExportWriter(
            url: url, format: .wav(options)
        )

        // 1024-frame silent buffer at 22 050 Hz mono float32 (the
        // exporter always feeds float32 input; the writer
        // converts).
        let inFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 22_050,
            channels: 1,
            interleaved: false
        )!
        let buf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: 1024)!
        buf.frameLength = 1024

        try await writer.write(buf)
        try await writer.finish()

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 22_050)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.length == 1024)
    }

    @Test("AIFF writer round-trip")
    func aiffRoundTrip() async throws {
        let url = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("smwriter-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try PCMAudioExportWriter(
            url: url, format: .aiff(PCMOptions())
        )
        let inFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 2,
            interleaved: false
        )!
        let buf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: 512)!
        buf.frameLength = 512
        try await writer.write(buf)
        try await writer.finish()

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 44_100)
        #expect(file.fileFormat.channelCount == 2)
        #expect(file.length == 512)
    }
}
```

- [ ] **Step 2: Run, confirm fail**

```bash
swift test --filter PCMAudioExportWriterTests
```

Expected: compile failure — `cannot find 'PCMAudioExportWriter'`.

- [ ] **Step 3: Implement the writer**

Create `Sources/SheetMusicAudio/Export/AudioExportWriter.swift`:

```swift
import AVFoundation
import Foundation

/// Internal protocol. Hides the AVAudioFile / AVAssetWriter choice
/// from `AudioFileExporter`'s render loop.
///
/// All writers consume float32, non-interleaved `AVAudioPCMBuffer`s
/// at the output sample rate. They internally convert / encode as
/// needed for the destination format.
protocol AudioExportWriter: Sendable {
    func write(_ buffer: AVAudioPCMBuffer) async throws
    func finish() async throws
}

/// `AVAudioFile`-backed writer used for WAV and AIFF.
///
/// AVAudioFile infers the file container from the URL's extension.
/// We pick `.aifc` for AIFF when the user requested float32 PCM
/// (the AIFF spec is integer-only; AIFC is its float-capable
/// cousin); for int variants we stay on `.aiff`.
struct PCMAudioExportWriter: AudioExportWriter {
    let file: AVAudioFile

    init(url: URL, format: AudioFileFormat) throws {
        let options: PCMOptions
        switch format {
        case let .wav(o):  options = o
        case let .aiff(o): options = o
        default:
            throw AudioExportError.engineSetupFailed(
                underlying: "PCMAudioExportWriter requires .wav or .aiff"
            )
        }
        let resolvedURL = Self.resolveURL(url, for: format, bitDepth: options.bitDepth)

        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: options.sampleRate,
            AVNumberOfChannelsKey: options.channels.rawValue,
        ]
        switch options.bitDepth {
        case .int16:
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
        case .int24:
            settings[AVLinearPCMBitDepthKey] = 24
            settings[AVLinearPCMIsFloatKey] = false
        case .int32:
            settings[AVLinearPCMBitDepthKey] = 32
            settings[AVLinearPCMIsFloatKey] = false
        case .float32:
            settings[AVLinearPCMBitDepthKey] = 32
            settings[AVLinearPCMIsFloatKey] = true
        }
        settings[AVLinearPCMIsBigEndianKey] = (resolvedURL.pathExtension.lowercased() == "aiff")
        settings[AVLinearPCMIsNonInterleavedKey] = false

        do {
            self.file = try AVAudioFile(
                forWriting: resolvedURL,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw AudioExportError.fileWriteFailed(
                underlying: (error as NSError).localizedDescription
            )
        }
    }

    /// Float32 PCM in AIFF requires the .aifc extension. Caller
    /// passes a `.aiff` URL; we rewrite to `.aifc` for the float
    /// row.
    private static func resolveURL(
        _ url: URL, for format: AudioFileFormat, bitDepth: PCMBitDepth
    ) -> URL {
        if case .aiff = format, bitDepth == .float32 {
            return url.deletingPathExtension().appendingPathExtension("aifc")
        }
        return url
    }

    func write(_ buffer: AVAudioPCMBuffer) async throws {
        do {
            try file.write(from: buffer)
        } catch {
            throw AudioExportError.fileWriteFailed(
                underlying: (error as NSError).localizedDescription
            )
        }
    }

    func finish() async throws {
        // AVAudioFile closes on deallocation; nothing to do.
    }
}
```

- [ ] **Step 4: Run, confirm pass**

```bash
swift test --filter PCMAudioExportWriterTests
```

Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicAudio/Export/AudioExportWriter.swift \
        Tests/SheetMusicTests/AudioFileExporterTests.swift
git commit -m "audio: add PCMAudioExportWriter for WAV/AIFF"
```

---

## Task 6: M4A writer (`AVAudioFile` with AAC settings)

**Files:**
- Modify: `Sources/SheetMusicAudio/Export/AudioExportWriter.swift`
- Test: extend `Tests/SheetMusicTests/AudioFileExporterTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/SheetMusicTests/AudioFileExporterTests.swift`:

```swift
@Suite("CompressedAudioExportWriter (M4A)")
struct CompressedAudioExportWriterTests {
    @Test("M4A writer produces an AAC file")
    func m4aRoundTrip() async throws {
        let url = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("smwriter-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try CompressedAudioExportWriter(
            url: url, format: .m4a(CompressedOptions(bitRate: 128_000))
        )
        let inFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 2,
            interleaved: false
        )!
        // A single 4096-frame buffer of silence — enough for AAC to
        // emit at least one frame.
        let buf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: 4096)!
        buf.frameLength = 4096
        try await writer.write(buf)
        try await writer.finish()

        let file = try AVAudioFile(forReading: url)
        let desc = file.fileFormat.streamDescription.pointee
        #expect(desc.mFormatID == kAudioFormatMPEG4AAC)
    }
}
```

- [ ] **Step 2: Run, confirm fail**

```bash
swift test --filter CompressedAudioExportWriterTests
```

Expected: compile failure — `cannot find 'CompressedAudioExportWriter'`.

- [ ] **Step 3: Implement**

Append to `Sources/SheetMusicAudio/Export/AudioExportWriter.swift`:

```swift
/// `AVAudioFile`-backed writer for AAC (M4A).
struct CompressedAudioExportWriter: AudioExportWriter {
    let file: AVAudioFile

    init(url: URL, format: AudioFileFormat) throws {
        let options: CompressedOptions
        switch format {
        case let .m4a(o): options = o
        default:
            throw AudioExportError.engineSetupFailed(
                underlying: "CompressedAudioExportWriter requires .m4a"
            )
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: options.sampleRate,
            AVNumberOfChannelsKey: options.channels.rawValue,
            AVEncoderBitRateKey: options.bitRate,
        ]
        do {
            self.file = try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw AudioExportError.fileWriteFailed(
                underlying: (error as NSError).localizedDescription
            )
        }
    }

    func write(_ buffer: AVAudioPCMBuffer) async throws {
        do {
            try file.write(from: buffer)
        } catch {
            throw AudioExportError.fileWriteFailed(
                underlying: (error as NSError).localizedDescription
            )
        }
    }

    func finish() async throws {
        // AVAudioFile closes on dealloc.
    }
}
```

- [ ] **Step 4: Run, confirm pass**

```bash
swift test --filter CompressedAudioExportWriterTests
```

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicAudio/Export/AudioExportWriter.swift \
        Tests/SheetMusicTests/AudioFileExporterTests.swift
git commit -m "audio: add CompressedAudioExportWriter for M4A"
```

---

## Task 7: MP3 writer (`AVAssetWriter`, gated)

**Files:**
- Modify: `Sources/SheetMusicAudio/Export/AudioExportWriter.swift`
- Test: extend `Tests/SheetMusicTests/AudioFileExporterTests.swift`

- [ ] **Step 1: Write the failing test**

Append to `Tests/SheetMusicTests/AudioFileExporterTests.swift`:

```swift
@Suite("MP3AudioExportWriter")
struct MP3AudioExportWriterTests {
    @Test("MP3 writer produces an MP3 file (iOS 17+/macOS 14+)")
    func mp3RoundTrip() async throws {
        guard #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) else {
            return // gated; no-op on older OS
        }
        let url = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("smwriter-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try MP3AudioExportWriter(
            url: url, format: .mp3(CompressedOptions(bitRate: 128_000))
        )
        let inFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 2,
            interleaved: false
        )!
        let buf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: 4096)!
        buf.frameLength = 4096
        try await writer.write(buf)
        try await writer.finish()

        #expect(FileManager.default.fileExists(atPath: url.path))
        let file = try AVAudioFile(forReading: url)
        #expect(file.length > 0)
    }
}
```

- [ ] **Step 2: Run, confirm fail**

```bash
swift test --filter MP3AudioExportWriterTests
```

Expected: compile failure — `cannot find 'MP3AudioExportWriter'`.

- [ ] **Step 3: Implement**

Append to `Sources/SheetMusicAudio/Export/AudioExportWriter.swift`:

```swift
/// `AVAssetWriter`-backed MP3 writer. Gated on iOS 17 / macOS 14 /
/// tvOS 17 / watchOS 10 — earlier OSes have no MP3 *write* path
/// in `AVAssetWriter`.
@available(iOS 17, macOS 14, tvOS 17, watchOS 10, *)
final class MP3AudioExportWriter: AudioExportWriter, @unchecked Sendable {
    private let assetWriter: AVAssetWriter
    private let input: AVAssetWriterInput
    private var startedSession = false
    private var presentationFrames: Int64 = 0
    private let sampleRate: Double

    init(url: URL, format: AudioFileFormat) throws {
        let options: CompressedOptions
        switch format {
        case let .mp3(o): options = o
        default:
            throw AudioExportError.engineSetupFailed(
                underlying: "MP3AudioExportWriter requires .mp3"
            )
        }
        do {
            self.assetWriter = try AVAssetWriter(outputURL: url, fileType: .mp3)
        } catch {
            throw AudioExportError.fileWriteFailed(
                underlying: (error as NSError).localizedDescription
            )
        }
        self.sampleRate = options.sampleRate

        let inputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEGLayer3,
            AVSampleRateKey: options.sampleRate,
            AVNumberOfChannelsKey: options.channels.rawValue,
            AVEncoderBitRateKey: options.bitRate,
        ]
        self.input = AVAssetWriterInput(
            mediaType: .audio, outputSettings: inputSettings
        )
        self.input.expectsMediaDataInRealTime = false
        assetWriter.add(input)

        guard assetWriter.startWriting() else {
            throw AudioExportError.fileWriteFailed(
                underlying: assetWriter.error?.localizedDescription
                    ?? "AVAssetWriter.startWriting returned false"
            )
        }
    }

    func write(_ buffer: AVAudioPCMBuffer) async throws {
        // Convert AVAudioPCMBuffer (float32, non-interleaved) into
        // a CMSampleBuffer with PTS in frames.
        guard let sampleBuffer = try? makeCMSampleBuffer(
            from: buffer, pts: presentationFrames
        ) else {
            throw AudioExportError.fileWriteFailed(
                underlying: "Could not wrap PCM buffer as CMSampleBuffer"
            )
        }
        if !startedSession {
            assetWriter.startSession(
                atSourceTime: CMTime(value: 0, timescale: CMTimeScale(sampleRate))
            )
            startedSession = true
        }
        // AVAssetWriterInput.append blocks until the writer is ready
        // for more; here we just spin briefly. For 4096-frame
        // buffers this is microsecond-scale; for production use a
        // requestMediaDataWhenReady callback is preferable.
        while !input.isReadyForMoreMediaData {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard input.append(sampleBuffer) else {
            throw AudioExportError.fileWriteFailed(
                underlying: assetWriter.error?.localizedDescription
                    ?? "AVAssetWriterInput.append returned false"
            )
        }
        presentationFrames += Int64(buffer.frameLength)
    }

    func finish() async throws {
        input.markAsFinished()
        await assetWriter.finishWriting()
        if assetWriter.status == .failed {
            throw AudioExportError.fileWriteFailed(
                underlying: assetWriter.error?.localizedDescription
                    ?? "AVAssetWriter.finishWriting reported failure"
            )
        }
    }

    private func makeCMSampleBuffer(
        from buffer: AVAudioPCMBuffer, pts: Int64
    ) throws -> CMSampleBuffer {
        // We have non-interleaved float32. Build an
        // AudioStreamBasicDescription for it, then wrap the float
        // channel pointers in a CMBlockBuffer, and build a
        // CMSampleBuffer with PTS = pts / sampleRate.
        var asbd = buffer.format.streamDescription.pointee
        var formatDesc: CMAudioFormatDescription?
        var status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        guard status == noErr, let fmt = formatDesc else {
            throw AudioExportError.fileWriteFailed(
                underlying: "CMAudioFormatDescriptionCreate failed (\(status))"
            )
        }
        var sb: CMSampleBuffer?
        let pts = CMTime(value: pts, timescale: CMTimeScale(sampleRate))
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fmt,
            sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: [
                CMSampleTimingInfo(
                    duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
                    presentationTimeStamp: pts,
                    decodeTimeStamp: .invalid
                ),
            ],
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sb
        )
        guard status == noErr, let sb else {
            throw AudioExportError.fileWriteFailed(
                underlying: "CMSampleBufferCreate failed (\(status))"
            )
        }
        status = CMSampleBufferSetDataBufferFromAudioBufferList(
            sb,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: buffer.audioBufferList
        )
        guard status == noErr else {
            throw AudioExportError.fileWriteFailed(
                underlying: "CMSampleBufferSetDataBuffer failed (\(status))"
            )
        }
        return sb
    }
}
```

- [ ] **Step 4: Run, confirm pass**

```bash
swift test --filter MP3AudioExportWriterTests
```

Expected: PASS on iOS 17+/macOS 14+ host; no-op on older.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicAudio/Export/AudioExportWriter.swift \
        Tests/SheetMusicTests/AudioFileExporterTests.swift
git commit -m "audio: add MP3AudioExportWriter (iOS 17+/macOS 14+)"
```

---

## Task 8: `AudioFileExporter` actor — offline-render loop

**Files:**
- Create: `Sources/SheetMusicAudio/Export/AudioFileExporter.swift`
- Test: extend `Tests/SheetMusicTests/AudioFileExporterTests.swift`

**Background:** This task drives the engine in offline mode and wires
buffers into the writer. The next task (Task 9) wraps it in the
public `PlaybackEngine.exportAudioFile(...)` method and tests the
full pipeline with a real `Score`. For Task 8 we test only the
lowest-level "build a writer for this format" factory; the render
loop is exercised end-to-end in Task 9.

- [ ] **Step 1: Write the failing test**

Append to `Tests/SheetMusicTests/AudioFileExporterTests.swift`:

```swift
@Suite("AudioFileExporter writer factory")
struct AudioFileExporterFactoryTests {
    @Test("Factory picks PCM writer for .wav")
    func picksPCMForWav() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("smfactory-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AudioFileExporter
            .makeWriter(url: url, format: .wav())
        #expect(writer is PCMAudioExportWriter)
    }

    @Test("Factory picks Compressed writer for .m4a")
    func picksCompressedForM4a() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("smfactory-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AudioFileExporter
            .makeWriter(url: url, format: .m4a())
        #expect(writer is CompressedAudioExportWriter)
    }

    @Test("Factory throws .formatUnsupportedOnThisOS for .mp3 on old OS")
    func mp3GatedOnOldOS() async throws {
        if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) {
            return // Can't test the gate on a host that supports MP3.
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("smfactory-\(UUID().uuidString).mp3")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try AudioFileExporter
                .makeWriter(url: url, format: .mp3())
            Issue.record("Expected throw")
        } catch let AudioExportError.formatUnsupportedOnThisOS(.mp3) {
            // ok
        }
    }
}
```

- [ ] **Step 2: Run, confirm fail**

```bash
swift test --filter AudioFileExporterFactoryTests
```

Expected: compile failure.

- [ ] **Step 3: Implement the exporter actor**

Create `Sources/SheetMusicAudio/Export/AudioFileExporter.swift`:

```swift
import AVFoundation
import Foundation
import SheetMusicCore
import SheetMusicMIDI

/// Drives `AVAudioEngine` in offline manual rendering mode and
/// pumps each rendered buffer into an `AudioExportWriter`.
///
/// Owned and invoked by `PlaybackEngine.exportAudioFile(...)`. The
/// public surface is small on purpose; engine setup / teardown
/// stays in `PlaybackEngine+Export` so the lifecycle invariants
/// (manual mode toggle, sequencer rebuild, audio session) all live
/// next to the existing `prepare(score:)` code.
@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
actor AudioFileExporter {
    /// Buffer size for each `engine.renderOffline(...)` pull. Apple
    /// docs recommend powers of two; 4096 is a sweet spot between
    /// allocation cost and progress-callback granularity.
    static let bufferFrames: AVAudioFrameCount = 4096

    /// Public factory used by `PlaybackEngine+Export` and by
    /// `AudioFileExporterFactoryTests`. MP3 path is gated.
    static func makeWriter(
        url: URL, format: AudioFileFormat
    ) throws -> AudioExportWriter {
        switch format {
        case .wav, .aiff:
            return try PCMAudioExportWriter(url: url, format: format)
        case .m4a:
            return try CompressedAudioExportWriter(url: url, format: format)
        case .mp3:
            if #available(iOS 17, macOS 14, tvOS 17, watchOS 10, *) {
                return try MP3AudioExportWriter(url: url, format: format)
            } else {
                throw AudioExportError.formatUnsupportedOnThisOS(format)
            }
        }
    }

    /// Resolve a format → output `AVAudioFormat` (always float32,
    /// non-interleaved) at the user-requested sample rate /
    /// channel count.
    static func outputFormat(for format: AudioFileFormat) -> AVAudioFormat {
        let (rate, channels): (Double, AudioChannelCount)
        switch format {
        case let .wav(o):  (rate, channels) = (o.sampleRate, o.channels)
        case let .aiff(o): (rate, channels) = (o.sampleRate, o.channels)
        case let .m4a(o):  (rate, channels) = (o.sampleRate, o.channels)
        case let .mp3(o):  (rate, channels) = (o.sampleRate, o.channels)
        }
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: rate,
            channels: AVAudioChannelCount(channels.rawValue),
            interleaved: false
        )!
    }

    /// Render `framesToRender` from `engine` (already in offline
    /// manual rendering mode) to `writer`, reporting progress
    /// via `progress` and honouring cancellation.
    ///
    /// `engine` and `sequencer` must already be primed by the
    /// caller. This method does NOT toggle manual rendering mode
    /// on/off — that's the caller's responsibility so it can keep
    /// teardown in lockstep with `PlaybackEngine` lifecycle.
    func renderLoop(
        engine: AVAudioEngine,
        outputFormat: AVAudioFormat,
        framesToRender: AVAudioFrameCount,
        writer: AudioExportWriter,
        progress: (@Sendable (Double) -> Void)?
    ) async throws {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat, frameCapacity: Self.bufferFrames
        ) else {
            throw AudioExportError.engineSetupFailed(
                underlying: "Could not allocate AVAudioPCMBuffer"
            )
        }
        var framesWritten: AVAudioFrameCount = 0
        var lastProgressEmit = CFAbsoluteTimeGetCurrent()

        while framesWritten < framesToRender {
            try Task.checkCancellation()
            let remaining = framesToRender - framesWritten
            let request = min(Self.bufferFrames, remaining)
            buffer.frameLength = 0
            let status: AVAudioEngineManualRenderingStatus
            do {
                status = try engine.renderOffline(request, to: buffer)
            } catch {
                throw AudioExportError.engineSetupFailed(
                    underlying: (error as NSError).localizedDescription
                )
            }
            switch status {
            case .success, .insufficientDataFromInputNode:
                // No input nodes in our graph; insufficientData
                // is treated as success (it just means the buffer
                // is partially filled).
                try await writer.write(buffer)
                framesWritten += buffer.frameLength
                // Progress callback debounced at ~33ms.
                let now = CFAbsoluteTimeGetCurrent()
                if let progress, now - lastProgressEmit > 0.033 {
                    let p = min(
                        1.0,
                        Double(framesWritten) / Double(framesToRender)
                    )
                    await MainActor.run { progress(p) }
                    lastProgressEmit = now
                }
            case .cannotDoInCurrentContext:
                // Spin: engine is busy; brief pause and retry.
                try await Task.sleep(nanoseconds: 1_000_000)
            case .error:
                throw AudioExportError.engineSetupFailed(
                    underlying: "AVAudioEngine.renderOffline returned .error"
                )
            @unknown default:
                throw AudioExportError.engineSetupFailed(
                    underlying: "AVAudioEngine.renderOffline unknown status"
                )
            }
        }
        try await writer.finish()
        if let progress {
            await MainActor.run { progress(1.0) }
        }
    }
}
```

- [ ] **Step 4: Run, confirm pass**

```bash
swift test --filter AudioFileExporterFactoryTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicAudio/Export/AudioFileExporter.swift \
        Tests/SheetMusicTests/AudioFileExporterTests.swift
git commit -m "audio: add AudioFileExporter actor (offline render loop)"
```

---

## Task 9: `PlaybackEngine.exportAudioFile(...)` + integration tests

**Files:**
- Create: `Sources/SheetMusicAudio/PlaybackEngine+Export.swift`
- Test: extend `Tests/SheetMusicTests/AudioFileExporterTests.swift`

This is the largest task — the public method plus end-to-end tests
on a real `Score`. We use the existing `midi01.mscx` fixture and a
nil-returning `SoundfontResolver` (the samplers stay silent; the
test cares about frame count and metadata, not audible content).

- [ ] **Step 1: Write the failing test**

Append to `Tests/SheetMusicTests/AudioFileExporterTests.swift`:

```swift
import SheetMusicMSCX
import SheetMusicCore

/// Silent resolver — returns nil for everything. Sampler stays
/// silent but the offline rendering loop still produces valid
/// silent buffers, which is what these tests verify (we don't do
/// byte-level audio comparison).
private struct SilentResolver: SoundfontResolver {
    func soundfontURL(forBank bank: UInt8, program: UInt8, isDrums: Bool) -> URL? {
        nil
    }
    var defaultGMSoundfontURL: URL? { nil }
}

private func loadMidi01() throws -> Score {
    let url = Bundle.module.url(
        forResource: "midi01", withExtension: "mscx"
    )!
    return try MSCXParser.parse(contentsOf: url)
}

@available(macOS 13.0, iOS 16.0, *)
@Suite("PlaybackEngine.exportAudioFile (integration)")
@MainActor
struct PlaybackEngineExportTests {
    @Test("WAV export produces a readable file with correct format")
    func wavSmoke() async throws {
        let score = try loadMidi01()
        let engine = PlaybackEngine(soundfontResolver: SilentResolver())
        try engine.prepare(score: score)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("smexp-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        try await engine.exportAudioFile(
            to: url,
            score: score,
            format: .wav(PCMOptions(sampleRate: 22_050, bitDepth: .int16, channels: .stereo))
        )

        let file = try AVAudioFile(forReading: url)
        #expect(file.fileFormat.sampleRate == 22_050)
        #expect(file.fileFormat.channelCount == 2)
        #expect(file.length > 0)
        #expect(engine.state == .stopped)
    }

    @Test("AIFF export round-trips")
    func aiffSmoke() async throws {
        let score = try loadMidi01()
        let engine = PlaybackEngine(soundfontResolver: SilentResolver())
        try engine.prepare(score: score)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("smexp-\(UUID().uuidString).aiff")
        defer { try? FileManager.default.removeItem(at: url) }

        try await engine.exportAudioFile(
            to: url, score: score, format: .aiff()
        )
        let file = try AVAudioFile(forReading: url)
        #expect(file.length > 0)
    }

    @Test("M4A export round-trips and reports format ID AAC")
    func m4aSmoke() async throws {
        let score = try loadMidi01()
        let engine = PlaybackEngine(soundfontResolver: SilentResolver())
        try engine.prepare(score: score)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("smexp-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        try await engine.exportAudioFile(
            to: url, score: score, format: .m4a()
        )
        let file = try AVAudioFile(forReading: url)
        let desc = file.fileFormat.streamDescription.pointee
        #expect(desc.mFormatID == kAudioFormatMPEG4AAC)
    }

    @Test("Range export is shorter than full export")
    func rangeNarrowing() async throws {
        let score = try loadMidi01()
        let engine = PlaybackEngine(soundfontResolver: SilentResolver())
        try engine.prepare(score: score)

        // Full export
        let fullURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("smexp-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: fullURL) }
        try await engine.exportAudioFile(
            to: fullURL, score: score, format: .wav()
        )
        let fullFrames = try AVAudioFile(forReading: fullURL).length

        // First-measure-only export
        let firstCursor = ScoreCursor(
            staffIndex: 0, measureIndex: 0, voiceIndex: 0, elementIndex: 0
        )
        let secondMeasureCursor = ScoreCursor(
            staffIndex: 0, measureIndex: 1, voiceIndex: 0, elementIndex: 0
        )
        let regionURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("smexp-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: regionURL) }
        try await engine.exportAudioFile(
            to: regionURL,
            score: score,
            format: .wav(),
            range: .region(from: firstCursor, to: secondMeasureCursor)
        )
        let regionFrames = try AVAudioFile(forReading: regionURL).length
        #expect(regionFrames < fullFrames)
        #expect(regionFrames > 0)
    }

    @Test("Throws .noScorePrepared when prepare wasn't called")
    func errorNoScorePrepared() async throws {
        let score = try loadMidi01()
        let engine = PlaybackEngine(soundfontResolver: SilentResolver())
        // intentionally skip prepare

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("smexp-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            try await engine.exportAudioFile(
                to: url, score: score, format: .wav()
            )
            Issue.record("Expected throw")
        } catch AudioExportError.noScorePrepared {
            // ok
        }
    }

    @Test("Cancellation removes the partial file")
    func cancellationCleansUp() async throws {
        let score = try loadMidi01()
        let engine = PlaybackEngine(soundfontResolver: SilentResolver())
        try engine.prepare(score: score)

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("smexp-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        let task = Task { @MainActor in
            try await engine.exportAudioFile(
                to: url, score: score, format: .wav()
            )
        }
        // Cancel immediately. The export starts on the current
        // actor so the first awaited hop is where cancellation
        // takes effect.
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation throw")
        } catch is CancellationError {
            // ok
        } catch AudioExportError.cancelled {
            // ok
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(engine.state == .stopped)
    }
}
```

- [ ] **Step 2: Run, confirm fail**

```bash
swift test --filter PlaybackEngineExportTests
```

Expected: compile failure — `cannot find 'exportAudioFile' on 'PlaybackEngine'`.

- [ ] **Step 3: Implement `PlaybackEngine+Export.swift`**

Create `Sources/SheetMusicAudio/PlaybackEngine+Export.swift`:

```swift
import AVFoundation
import Foundation
import SheetMusicCore
import SheetMusicMIDI

@available(macOS 13.0, iOS 16.0, tvOS 16.0, watchOS 9.0, *)
extension PlaybackEngine {
    /// Offline-render the prepared score to an audio file at `url`.
    ///
    /// The exported audio reflects the live engine state: mixer
    /// (volume / mute / solo), per-staff program changes,
    /// metronome on/off, and the current playback rate. While
    /// rendering, the engine is in manual rendering mode and
    /// `state == .exporting`; normal playback is suspended. On
    /// completion / failure / cancellation the engine is restored
    /// and `state` returns to `.stopped`.
    ///
    /// `prepare(score:)` must have been called for the same `score`
    /// instance; otherwise throws `.noScorePrepared`.
    ///
    /// On `Task.cancel()` the in-flight render is aborted at the
    /// next buffer boundary; the partial output file at `url` is
    /// deleted.
    public func exportAudioFile(
        to url: URL,
        score: Score,
        format: AudioFileFormat,
        range: AudioExportRange = .full,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        // 1. State / preconditions.
        // `Score` is value-typed; we don't compare instances (the
        // user-facing contract is "call prepare(score:) for the
        // score you then export"). `timeline` is set by
        // `prepare(score:)`, so its presence is our precondition.
        // `buildSequencerForExport(score:)` below handles the
        // "no sequencer yet" and "different score than last play"
        // cases internally.
        guard let timeline = exportTimeline() else {
            throw AudioExportError.noScorePrepared
        }

        let (startTick, endTick) = try Self.resolveRange(
            range, timeline: timeline, loop: loopRange
        )
        let startSec = timeline.frame(atTick: startTick)?.timeSeconds ?? 0
        let endSec = timeline.frame(atTick: endTick)?.timeSeconds
            ?? timeline.totalSeconds
        let durationSec = max(0, endSec - startSec)

        let outputFormat = AudioFileExporter.outputFormat(for: format)
        let framesToRender = AVAudioFrameCount(
            (durationSec * outputFormat.sampleRate).rounded(.up)
        )
        let writer = try AudioFileExporter.makeWriter(url: url, format: format)
        let exporter = AudioFileExporter()

        // 2. Suspend playback.
        setStateForExport(.exporting)
        let engine = exportEngine()
        let previouslyRunning = engine.isRunning
        exportSequencer()?.stop()
        if engine.isRunning {
            engine.pause()
        }

        do {
            // 3. Switch to manual rendering mode at the chosen format.
            try engine.enableManualRenderingMode(
                .offline,
                format: outputFormat,
                maximumFrameCount: AudioFileExporter.bufferFrames
            )
            try engine.start()

            // 4. (Re)build sequencer for this score and position it
            //    at the start tick.
            try buildSequencerForExport(score: score)
            guard let sequencer = exportSequencer() else {
                throw AudioExportError.engineSetupFailed(
                    underlying: "Sequencer build failed"
                )
            }
            sequencer.currentPositionInBeats =
                Double(startTick) / Double(timeline.division)
            sequencer.prepareToPlay()
            try sequencer.start()

            // 5. Render loop.
            try await exporter.renderLoop(
                engine: engine,
                outputFormat: outputFormat,
                framesToRender: framesToRender,
                writer: writer,
                progress: progress
            )

            // 6. Teardown.
            sequencer.stop()
            engine.stop()
            engine.disableManualRenderingMode()
            if previouslyRunning {
                try? engine.start()
            }
            setStateForExport(.stopped)
        } catch is CancellationError {
            await teardownAfterExportFailure(
                engine: engine, previouslyRunning: previouslyRunning,
                url: url
            )
            throw AudioExportError.cancelled
        } catch let err as AudioExportError {
            await teardownAfterExportFailure(
                engine: engine, previouslyRunning: previouslyRunning,
                url: url
            )
            throw err
        } catch {
            await teardownAfterExportFailure(
                engine: engine, previouslyRunning: previouslyRunning,
                url: url
            )
            throw AudioExportError.engineSetupFailed(
                underlying: (error as NSError).localizedDescription
            )
        }
    }

    private func teardownAfterExportFailure(
        engine: AVAudioEngine, previouslyRunning: Bool, url: URL
    ) async {
        exportSequencer()?.stop()
        engine.stop()
        engine.disableManualRenderingMode()
        if previouslyRunning {
            try? engine.start()
        }
        try? FileManager.default.removeItem(at: url)
        setStateForExport(.stopped)
    }

    private static func resolveRange(
        _ range: AudioExportRange,
        timeline: PlaybackTimeline,
        loop: LoopRange?
    ) throws -> (Int, Int) {
        switch range {
        case .full:
            return (0, timeline.totalTicks)
        case .currentLoop:
            if let loop {
                return (loop.startTick, loop.endTick)
            }
            return (0, timeline.totalTicks)
        case let .region(from, to):
            guard let s = timeline.frame(forCursor: from),
                  let e = timeline.frame(forCursor: to),
                  s.tick < e.tick
            else { throw AudioExportError.rangeNotInTimeline }
            return (s.tick, e.tick)
        case let .regionThroughEnd(from, last):
            guard let s = timeline.frame(forCursor: from),
                  let endTick = timeline.itemEndTicks[last],
                  s.tick < endTick
            else { throw AudioExportError.rangeNotInTimeline }
            return (s.tick, endTick)
        }
    }
}
```

The above uses several **internal accessors** on `PlaybackEngine`
that don't yet exist. Add them now to `Sources/SheetMusicAudio/PlaybackEngine.swift`,
near the other `// MARK: Internal accessors` block:

```swift
// MARK: Internal accessors for `PlaybackEngine+Export`

func exportEngine() -> AVAudioEngine { engine }
func exportSequencer() -> AVAudioSequencer? { sequencer }
func exportSequencerScore() -> Score? { sequencerScore }
func exportTimeline() -> PlaybackTimeline? { timeline }

/// Build a sequencer suitable for offline export. Mirrors the
/// private `buildSequencer` used by `play(...)`, but is callable
/// from the export path even when `state == .exporting`.
///
/// `Score` is value-typed; we use `!=` (Equatable) the same way
/// the existing `play(from:in:)` does its rebuild check.
func buildSequencerForExport(score: Score) throws {
    if sequencer != nil, sequencerScore == score { return }
    try buildSequencer(for: score)
    sequencerScore = score
}
```

`buildSequencer(for:)` is currently `private`. Promote it to
`internal` (drop the `private` keyword) so the new
`buildSequencerForExport` can call it.

If the engineer finds that the existing `buildSequencer` resets state
in a way the export path doesn't want (e.g. clearing
`originalTrackLengths` mid-loop), don't refactor blindly — read the
method and decide based on what's already there. The shipping `play(...)`
path already calls it on an already-built sequencer (it short-circuits
on `sequencerScore == score`), so the export path's pre-check matches.

- [ ] **Step 4: Run, confirm pass**

```bash
swift test --filter PlaybackEngineExportTests
```

Expected: PASS (6 tests). M4A test may be slow on first run.

- [ ] **Step 5: Run the full suite**

```bash
swift test
```

Expected: 100% green (existing 48+ tests + the new export tests).

- [ ] **Step 6: Lint**

```bash
swiftlint --quiet Sources Tests
```

Expected: 0 warnings, 0 errors.

- [ ] **Step 7: Commit**

```bash
git add Sources/SheetMusicAudio/PlaybackEngine+Export.swift \
        Sources/SheetMusicAudio/PlaybackEngine.swift \
        Tests/SheetMusicTests/AudioFileExporterTests.swift
git commit -m "audio: add PlaybackEngine.exportAudioFile + integration tests"
```

---

## Task 10: README — SwiftUI Picker pattern doc

**Files:**
- Create: `Sources/SheetMusicAudio/README.md`

- [ ] **Step 1: Write the README**

Create `Sources/SheetMusicAudio/README.md`:

```markdown
# SheetMusicAudio

AVFoundation-backed audio for `swift-sheet-music`:
- Per-staff `AVAudioUnitSampler` playback driven by a SoundFont
  resolver.
- Mixer (per-staff volume / mute / solo) and a built-in metronome.
- Timeline-driven full-score playback with looping and cursor
  feedback.
- Offline audio-file export (WAV / AIFF / M4A / MP3).

## Audio file export

```swift
let engine = PlaybackEngine(soundfontResolver: myResolver)
try engine.prepare(score: score)

let url = URL(fileURLWithPath: "/tmp/song.wav")
try await engine.exportAudioFile(
    to: url,
    score: score,
    format: .wav(PCMOptions(sampleRate: 48_000, bitDepth: .int24))
)
```

The exported file reflects the live engine state — mixer levels,
per-staff GM program changes, metronome on/off, and the current
playback rate.

### SwiftUI picker pattern

`AudioFileFormat` is an enum with associated values, so it doesn't
bind directly to a `Picker`. The recommended host pattern is a
companion tag enum + per-format options state:

```swift
enum FormatTag: String, CaseIterable, Identifiable {
    case wav, aiff, m4a, mp3
    var id: Self { self }
}

@State private var tag: FormatTag = .wav
@State private var pcm = PCMOptions()
@State private var comp = CompressedOptions()

private var format: AudioFileFormat {
    switch tag {
    case .wav:  .wav(pcm)
    case .aiff: .aiff(pcm)
    case .m4a:  .m4a(comp)
    case .mp3:  .mp3(comp)
    }
}

var body: some View {
    Picker("Format", selection: $tag) {
        ForEach(FormatTag.allCases) { Text($0.rawValue.uppercased()).tag($0) }
    }
}
```

### Progress / cancellation

```swift
let task = Task {
    try await engine.exportAudioFile(
        to: url, score: score, format: .wav(),
        progress: { p in /* update UI; called on MainActor */ }
    )
}
// later, to cancel:
task.cancel()
```

A cancelled export deletes the partial file.

### Platform notes

- **MP3** requires iOS 17 / macOS 14 / tvOS 17 / watchOS 10 (it
  uses `AVAssetWriter`'s MP3 write path). Calling `exportAudioFile`
  with `.mp3(...)` on older OS throws
  `AudioExportError.formatUnsupportedOnThisOS(.mp3(...))`.
- **AIFF float32** is stored as AIFC; the writer rewrites the
  extension to `.aifc` in that case.
```

- [ ] **Step 2: Commit**

```bash
git add Sources/SheetMusicAudio/README.md
git commit -m "docs: SheetMusicAudio README — export usage + Picker pattern"
```

---

## Task 11: Example app — Export sheet (iOS + macOS)

**Files:**
- Create: `Example/SheetMusicExample/Audio/AudioExportSheet.swift`
- Modify: an iOS host view (find the toolbar where the existing
  playback / share buttons live) and a macOS host view, to present
  the sheet.

This task is hand-verified, not unit-tested. The engineer drives
the sheet on the macOS example app per CLAUDE.md ("Visual
verification — Mac app").

- [ ] **Step 1: Create the sheet view**

Create `Example/SheetMusicExample/Audio/AudioExportSheet.swift`:

```swift
import SheetMusicAudio
import SheetMusicCore
import SwiftUI

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

enum FormatTag: String, CaseIterable, Identifiable {
    case wav, aiff, m4a, mp3
    var id: Self { self }
}

struct AudioExportSheet: View {
    let engine: PlaybackEngine
    let score: Score
    @Environment(\.dismiss) private var dismiss

    @State private var tag: FormatTag = .wav
    @State private var pcm = PCMOptions()
    @State private var comp = CompressedOptions()
    @State private var progress: Double = 0
    @State private var exportTask: Task<Void, Error>?
    @State private var errorText: String?

    var body: some View {
        Form {
            Section("Format") {
                Picker("Container", selection: $tag) {
                    ForEach(FormatTag.allCases) {
                        Text($0.rawValue.uppercased()).tag($0)
                    }
                }
            }
            if isPCM {
                Section("PCM options") {
                    Stepper("Sample rate: \(Int(pcm.sampleRate)) Hz",
                            value: $pcm.sampleRate,
                            in: 8_000...192_000,
                            step: 100)
                    Picker("Bit depth", selection: $pcm.bitDepth) {
                        Text("16-bit int").tag(PCMBitDepth.int16)
                        Text("24-bit int").tag(PCMBitDepth.int24)
                        Text("32-bit int").tag(PCMBitDepth.int32)
                        Text("32-bit float").tag(PCMBitDepth.float32)
                    }
                    Picker("Channels", selection: $pcm.channels) {
                        Text("Mono").tag(AudioChannelCount.mono)
                        Text("Stereo").tag(AudioChannelCount.stereo)
                    }
                }
            } else {
                Section("Compressed options") {
                    Stepper("Sample rate: \(Int(comp.sampleRate)) Hz",
                            value: $comp.sampleRate,
                            in: 8_000...96_000,
                            step: 100)
                    Stepper("Bit rate: \(comp.bitRate / 1000) kbps",
                            value: $comp.bitRate,
                            in: 64_000...320_000,
                            step: 16_000)
                    Picker("Channels", selection: $comp.channels) {
                        Text("Mono").tag(AudioChannelCount.mono)
                        Text("Stereo").tag(AudioChannelCount.stereo)
                    }
                }
            }
            if exportTask != nil {
                Section {
                    ProgressView(value: progress)
                    Button("Cancel", role: .cancel) { exportTask?.cancel() }
                }
            } else {
                Section {
                    Button("Export…") { Task { await startExport() } }
                }
            }
            if let errorText {
                Section { Text(errorText).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Export audio")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") { dismiss() }
            }
        }
    }

    private var isPCM: Bool { tag == .wav || tag == .aiff }

    private var resolvedFormat: AudioFileFormat {
        switch tag {
        case .wav:  return .wav(pcm)
        case .aiff: return .aiff(pcm)
        case .m4a:  return .m4a(comp)
        case .mp3:  return .mp3(comp)
        }
    }

    private func startExport() async {
        let suggested = "score.\(tag.rawValue)"
        guard let url = await pickSaveURL(suggestedName: suggested) else {
            return
        }
        errorText = nil
        progress = 0
        exportTask = Task { @MainActor in
            do {
                try await engine.exportAudioFile(
                    to: url, score: score,
                    format: resolvedFormat,
                    progress: { p in progress = p }
                )
                exportTask = nil
                dismiss()
            } catch {
                exportTask = nil
                if !(error is CancellationError) {
                    errorText = String(describing: error)
                }
            }
        }
    }

    /// Platform-specific save dialog. iOS uses a `.fileExporter`
    /// presentation in a host view; for the example app we keep it
    /// simple and dump to the temporary directory.
    private func pickSaveURL(suggestedName: String) async -> URL? {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        return panel.runModal() == .OK ? panel.url : nil
        #else
        return FileManager.default.temporaryDirectory
            .appendingPathComponent(suggestedName)
        #endif
    }
}
```

- [ ] **Step 2: Wire the sheet into iOS and macOS root views**

Find the existing toolbar in the iOS and macOS root views (the
engineer should grep for `toolbar` / `Toolbar` inside
`Example/SheetMusicExample/iOS/` and `Example/SheetMusicExample/macOS/`).
Add a button alongside the existing playback / share controls:

```swift
@State private var showExport = false

// inside toolbar:
Button { showExport = true } label: { Image(systemName: "waveform") }
    .help("Export audio")
    .sheet(isPresented: $showExport) {
        AudioExportSheet(engine: playbackEngine, score: score)
    }
```

(`playbackEngine` and `score` references depend on what the host
view holds — pass whatever the existing transport controls already
have.)

- [ ] **Step 3: Regenerate the Xcode project**

```bash
cd Example && xcodegen generate
```

- [ ] **Step 4: Build the macOS scheme**

```bash
xcodebuild -project Example/SheetMusicExample.xcodeproj \
           -scheme SheetMusicExampleMac \
           build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Build the iOS Simulator scheme**

```bash
xcodebuild -project Example/SheetMusicExample.xcodeproj \
           -scheme SheetMusicExample \
           -destination 'platform=iOS Simulator,name=iPhone 17' build
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Visual verification (Mac)**

Launch the macOS example app, load a score, click the new
waveform toolbar button → tweak format/options → Export.

Listen to the exported file (open in QuickTime). Expected:
- WAV / AIFF play back at the chosen sample rate / bit depth.
- M4A plays back; file is noticeably smaller than the WAV.
- MP3 (if on iOS 17+/macOS 14+) plays back.
- Progress bar advances; Cancel deletes the file.

- [ ] **Step 7: Commit**

```bash
git add Example/SheetMusicExample/Audio/AudioExportSheet.swift \
        Example/SheetMusicExample/iOS/ \
        Example/SheetMusicExample/macOS/
git commit -m "example: add Export audio sheet (iOS + macOS)"
```

---

## Task 12: Update `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update the Library layout section**

The current diagram lists 3 sub-libraries; the real `Package.swift`
ships 8 public libraries + 1 internal target + 1 executable.
Replace the "Library layout" section's contents with:

```markdown
## Library layout

Public library products under this single package:

```
SheetMusic            (umbrella + small façade)
  ├─→ SheetMusicCore     (Score data model, SheetMusicError; no I/O)
  ├─→ SheetMusicMSCX     (mscx / mscz parsing + writing; → Core, XMLTools, ZIP)
  ├─→ SheetMusicMusicXML (MusicXML / MXL import; → Core, XMLTools, ZIP)
  └─→ SheetMusicMIDI     (in-memory MIDI model, render, SMF I/O; → Core)

SheetMusicLayout      (pure-geometry layout; → Core)
SheetMusicUI          (SwiftUI views; → Core, Layout)
SheetMusicAudio       (AVFoundation playback + audio file export; → Core, MIDI)
SheetMusicPDF         (PDF export; → Core, Layout, UI)
```

Internal targets (not products): `SheetMusicXMLTools`.

Dev executable: `RenderPreviews`.

`SheetMusic` re-exports Core + MSCX + MusicXML + MIDI with
`@_exported import` and adds the convenience façade. `Layout`,
`UI`, `Audio`, and `PDF` are not re-exported (consumers opt in
explicitly).
```

- [ ] **Step 2: Update the File layout section**

In the "File layout (source)" tree, add the new sub-tree:

```
Sources/SheetMusicAudio/Export/
  AudioFileFormat.swift, AudioExportRange.swift,
  AudioExportError.swift, AudioExportWriter.swift,
  AudioFileExporter.swift
Sources/SheetMusicAudio/PlaybackEngine+Export.swift
```

- [ ] **Step 3: Add an entry under "Recurring pitfalls"**

Append to the "Recurring pitfalls" section:

```markdown
- **Audio file writer back-ends differ by format**: `AVAudioFile`
  natively writes WAV (URL `.wav`), AIFF (`.aiff` int / `.aifc`
  float), and M4A (settings dict `kAudioFormatMPEG4AAC`). Only
  MP3 needs `AVAssetWriter` (and only on iOS 17 / macOS 14+). Do
  not reach for `AVAssetWriter` for the others — it is more code
  for no benefit. See `SheetMusicAudio/Export/AudioExportWriter.swift`.
```

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: CLAUDE.md — bring library/file layout up to date; audio export pitfall"
```

---

## Verification gate (final)

Before declaring done:

- [ ] `swift test` passes (existing tests + all new ones).
- [ ] `swiftlint --quiet Sources Tests` reports 0 warnings / errors.
- [ ] iOS Simulator build of the example app succeeds.
- [ ] macOS build of `SheetMusicExampleMac` succeeds.
- [ ] Manual listen-test: WAV, AIFF, M4A all play back. MP3 plays
      back on a host running iOS 17+/macOS 14+.
- [ ] Cancellation in the example app removes the partial file.

---

## Notes for the engineer

- The exporter is **opinionated about the live engine state**. If
  you want a pure score → file API (no mixer/program/metronome
  influence), don't add a parallel path in this PR; track it as a
  follow-up. The user has explicitly chosen the "reflect playback
  state" form for v1.
- The example app's `pickSaveURL` is a deliberately simple stand-in
  for iOS. Don't spend time wiring a fully native iOS save flow —
  the engineer's audience is people listening to the macOS example,
  per the project's verification convention.
- If `buildSequencer(for:)` proves awkward to share between
  `play(...)` and the export path (e.g. metronome injection
  semantics differ in some way you discover mid-implementation),
  do not introduce a second sequencer-build path; tell the user
  and let them decide. The spec assumes one builder.
- `AVAudioEngine.renderOffline` is a synchronous call inside an
  `async` actor method. That's fine — the actor isolation means
  we don't run on the MainActor and don't block UI.
