# Custom Metronome Click — Phase 1 (Core WAV→SF2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Foundation-only WAV→SF2 builder (plus the override seam types) to `SheetMusicAudioCore` so a pair of click WAVs can be turned into an SF2 that maps strong→note 76 / weak→note 77 in a bank-128 percussion preset.

**Architecture:** Three new value-type units in `SheetMusicAudioCore` — `WavPcmReader` (PCM WAV → mono `Int16`), `ClickSoundFontBuilder` (samples → minimal SF2 `Data`), and the `MetronomeClickSource` / `MetronomeClickProvider` seam — backed by a small little-endian byte writer. Everything is Foundation-only and Android-compatible. An Apple-only test loads the generated SF2 into `AVAudioUnitSampler` and renders note 76 offline to prove the bytes are a valid, playable SF2.

**Tech Stack:** Swift, Foundation, Swift Testing (`@Test`/`#expect`). Validation test uses AVFoundation (`#if !os(Android)`).

**Spec:** `docs/superpowers/specs/2026-06-01-custom-metronome-click-design.md`

**Scope (Phase 1 only):** the Core library + tests. Apple integration (Phase 2) and Android integration (Phase 3) are separate plans and are NOT in scope here. No changes to `SheetMusicAudioApple`, `SheetMusicAndroidJNI`, Kotlin, or `Package.swift` (the files land in the existing `SheetMusicAudioCore` target).

**Working directory:** `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/.claude/worktrees/custom-metronome-click` (branch `worktree-custom-metronome-click`). Run all commands from there. Do NOT `cd` to the main worktree.

---

## File Structure

New source files (all in the existing `SheetMusicAudioCore` target):

- `Sources/SheetMusicAudioCore/Metronome/LittleEndianWriter.swift` — internal LE byte buffer for RIFF/SF2.
- `Sources/SheetMusicAudioCore/Metronome/MetronomeClickError.swift` — public error enum for WAV parsing.
- `Sources/SheetMusicAudioCore/Metronome/WavPcmReader.swift` — public PCM-WAV → mono `Int16` reader.
- `Sources/SheetMusicAudioCore/Metronome/ClickSoundFontBuilder.swift` — public samples → SF2 `Data` builder.
- `Sources/SheetMusicAudioCore/Metronome/MetronomeClickSource.swift` — public seam enum + provider protocol.

New test files (in the existing `SheetMusicTests` target):

- `Tests/SheetMusicTests/Metronome/LittleEndianWriterTests.swift`
- `Tests/SheetMusicTests/Metronome/WavTestSupport.swift` — in-memory WAV builder used by the reader tests (no binary fixtures committed).
- `Tests/SheetMusicTests/Metronome/WavPcmReaderTests.swift`
- `Tests/SheetMusicTests/Metronome/Sf2TestSupport.swift` — minimal SF2 chunk-walker used by the builder tests.
- `Tests/SheetMusicTests/Metronome/ClickSoundFontBuilderTests.swift`
- `Tests/SheetMusicTests/Metronome/ClickSoundFontSynthLoadTests.swift` — `#if !os(Android)` AVFoundation render check.
- `Tests/SheetMusicTests/Metronome/MetronomeClickSourceTests.swift`

`SheetMusicAudioCore` is already a dependency of `SheetMusicTests` (Package.swift line 107/161/167), so no manifest edits are needed.

---

## Task 1: `LittleEndianWriter`

**Files:**
- Create: `Sources/SheetMusicAudioCore/Metronome/LittleEndianWriter.swift`
- Test: `Tests/SheetMusicTests/Metronome/LittleEndianWriterTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/Metronome/LittleEndianWriterTests.swift`:

```swift
@testable import SheetMusicAudioCore
import Foundation
import Testing

@Suite struct LittleEndianWriterTests {
    @Test func writesLittleEndianIntegers() {
        var w = LittleEndianWriter()
        w.appendUInt8(0xAB)
        w.appendUInt16(0x1234)
        w.appendUInt32(0x89AB_CDEF)
        #expect(Array(w.data) == [
            0xAB,
            0x34, 0x12,
            0xEF, 0xCD, 0xAB, 0x89,
        ])
    }

    @Test func writesSignedInt16TwosComplement() {
        var w = LittleEndianWriter()
        w.appendInt16(-1)
        w.appendInt16(-32768)
        #expect(Array(w.data) == [0xFF, 0xFF, 0x00, 0x80])
    }

    @Test func appendsFourByteTag() {
        var w = LittleEndianWriter()
        w.appendTag("RIFF")
        #expect(Array(w.data) == Array("RIFF".utf8))
    }

    @Test func fixedStringZeroPadsAndTruncates() {
        var w = LittleEndianWriter()
        w.appendFixedString("AB", length: 4)
        w.appendFixedString("TOOLONGNAME", length: 4)
        #expect(Array(w.data) == [
            0x41, 0x42, 0x00, 0x00,
            0x54, 0x4F, 0x4F, 0x4C, // "TOOL"
        ])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LittleEndianWriterTests`
Expected: FAIL — "cannot find 'LittleEndianWriter' in scope".

- [ ] **Step 3: Write minimal implementation**

Create `Sources/SheetMusicAudioCore/Metronome/LittleEndianWriter.swift`:

```swift
import Foundation

/// Minimal little-endian byte buffer for building RIFF / SF2 files.
///
/// The MIDI `BinaryEncoder` in `SheetMusicMIDI` is big-endian (SMF byte
/// order), so it is intentionally not reused here — RIFF / SF2 is
/// little-endian.
struct LittleEndianWriter {
    private(set) var data = Data()

    mutating func appendUInt8(_ v: UInt8) {
        data.append(v)
    }

    mutating func appendUInt16(_ v: UInt16) {
        data.append(UInt8(v & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF))
    }

    mutating func appendInt16(_ v: Int16) {
        appendUInt16(UInt16(bitPattern: v))
    }

    mutating func appendUInt32(_ v: UInt32) {
        data.append(UInt8(v & 0xFF))
        data.append(UInt8((v >> 8) & 0xFF))
        data.append(UInt8((v >> 16) & 0xFF))
        data.append(UInt8((v >> 24) & 0xFF))
    }

    mutating func append(_ other: Data) {
        data.append(other)
    }

    /// Append a 4-byte ASCII chunk tag (e.g. "RIFF", "LIST", "smpl").
    mutating func appendTag(_ tag: String) {
        let bytes = Array(tag.utf8)
        precondition(bytes.count == 4, "RIFF tag must be 4 ASCII bytes: \(tag)")
        data.append(contentsOf: bytes)
    }

    /// Append a fixed-length field, zero-padded (or truncated) to `length`.
    /// Used for SF2's fixed 20-byte name fields.
    mutating func appendFixedString(_ s: String, length: Int) {
        var bytes = Array(s.utf8.prefix(length))
        bytes.append(contentsOf: repeatElement(UInt8(0), count: length - bytes.count))
        data.append(contentsOf: bytes)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LittleEndianWriterTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicAudioCore/Metronome/LittleEndianWriter.swift Tests/SheetMusicTests/Metronome/LittleEndianWriterTests.swift
git commit -m "feat(audio-core): add little-endian writer for SF2/RIFF"
```

---

## Task 2: `WavPcmReader` (+ `MetronomeClickError`)

**Files:**
- Create: `Sources/SheetMusicAudioCore/Metronome/MetronomeClickError.swift`
- Create: `Sources/SheetMusicAudioCore/Metronome/WavPcmReader.swift`
- Create: `Tests/SheetMusicTests/Metronome/WavTestSupport.swift`
- Test: `Tests/SheetMusicTests/Metronome/WavPcmReaderTests.swift`

- [ ] **Step 1: Write the in-memory WAV builder (test support)**

Create `Tests/SheetMusicTests/Metronome/WavTestSupport.swift`:

```swift
import Foundation

/// Builds a PCM WAV container in memory for the reader tests, so we don't
/// commit binary fixtures. Writes little-endian, as the WAV spec requires.
enum WavTestSupport {
    private static func u16(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
    }

    private static func u32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
         UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    /// Wrap `fmtChunk` + `dataChunk` payloads in a RIFF/WAVE container.
    private static func riff(fmt: [UInt8], data: [UInt8]) -> Data {
        var body: [UInt8] = Array("WAVE".utf8)
        body += Array("fmt ".utf8) + u32(UInt32(fmt.count)) + fmt
        body += Array("data".utf8) + u32(UInt32(data.count)) + data
        var out: [UInt8] = Array("RIFF".utf8) + u32(UInt32(body.count)) + body
        return Data(out)
    }

    private static func fmtChunk(
        audioFormat: UInt16, channels: UInt16, sampleRate: UInt32, bits: UInt16,
    ) -> [UInt8] {
        let blockAlign = channels * (bits / 8)
        let byteRate = sampleRate * UInt32(blockAlign)
        return u16(audioFormat) + u16(channels) + u32(sampleRate)
            + u32(byteRate) + u16(blockAlign) + u16(bits)
    }

    /// 16-bit integer PCM WAV. `interleaved` is the raw per-channel sample
    /// stream (length = frames * channels).
    static func pcm16(interleaved: [Int16], channels: UInt16, sampleRate: UInt32) -> Data {
        var data: [UInt8] = []
        for s in interleaved { data += u16(UInt16(bitPattern: s)) }
        return riff(
            fmt: fmtChunk(audioFormat: 1, channels: channels, sampleRate: sampleRate, bits: 16),
            data: data,
        )
    }

    /// 32-bit IEEE float WAV.
    static func float32(interleaved: [Float], channels: UInt16, sampleRate: UInt32) -> Data {
        var data: [UInt8] = []
        for s in interleaved { data += u32(s.bitPattern) }
        return riff(
            fmt: fmtChunk(audioFormat: 3, channels: channels, sampleRate: sampleRate, bits: 32),
            data: data,
        )
    }

    /// 24-bit PCM WAV (unsupported on purpose — for the rejection test).
    static func pcm24(frames: Int, channels: UInt16, sampleRate: UInt32) -> Data {
        let data = [UInt8](repeating: 0, count: frames * Int(channels) * 3)
        return riff(
            fmt: fmtChunk(audioFormat: 1, channels: channels, sampleRate: sampleRate, bits: 24),
            data: data,
        )
    }
}
```

- [ ] **Step 2: Write the failing reader test**

Create `Tests/SheetMusicTests/Metronome/WavPcmReaderTests.swift`:

```swift
@testable import SheetMusicAudioCore
import Foundation
import Testing

@Suite struct WavPcmReaderTests {
    @Test func reads16BitMono() throws {
        let wav = WavTestSupport.pcm16(
            interleaved: [100, -100, 200], channels: 1, sampleRate: 22050,
        )
        let result = try WavPcmReader.read(wav)
        #expect(result.samples == [100, -100, 200])
        #expect(result.sampleRate == 22050)
    }

    @Test func downmixes16BitStereoToMono() throws {
        // Frame 0: L=100 R=300 → 200. Frame 1: L=200 R=400 → 300.
        let wav = WavTestSupport.pcm16(
            interleaved: [100, 300, 200, 400], channels: 2, sampleRate: 44100,
        )
        let result = try WavPcmReader.read(wav)
        #expect(result.samples == [200, 300])
        #expect(result.sampleRate == 44100)
    }

    @Test func reads32BitFloatMono() throws {
        let wav = WavTestSupport.float32(
            interleaved: [0.0, 1.0, -1.0], channels: 1, sampleRate: 48000,
        )
        let result = try WavPcmReader.read(wav)
        #expect(result.samples == [0, 32767, -32767])
        #expect(result.sampleRate == 48000)
    }

    @Test func rejects24BitPcm() {
        let wav = WavTestSupport.pcm24(frames: 4, channels: 1, sampleRate: 44100)
        #expect(throws: MetronomeClickError.self) {
            _ = try WavPcmReader.read(wav)
        }
    }

    @Test func rejectsNonRiff() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
                            0x08, 0x09, 0x0A, 0x0B])
        #expect(throws: MetronomeClickError.self) {
            _ = try WavPcmReader.read(garbage)
        }
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter WavPcmReaderTests`
Expected: FAIL — "cannot find 'WavPcmReader' in scope" / "cannot find 'MetronomeClickError'".

- [ ] **Step 4: Write `MetronomeClickError`**

Create `Sources/SheetMusicAudioCore/Metronome/MetronomeClickError.swift`:

```swift
import Foundation

/// Errors raised while turning host-supplied click WAVs into a SoundFont.
///
/// A dedicated enum (rather than a new `SheetMusicError` case) keeps the
/// shared Core error type stable and avoids touching its exhaustive
/// switches.
public enum MetronomeClickError: Error, Sendable, Equatable {
    /// The bytes are not a valid PCM WAV: missing RIFF/WAVE header, no
    /// `fmt ` chunk, or no `data` chunk.
    case invalidWav(reason: String)
    /// The WAV uses a sample format the reader does not support. Only
    /// 16-bit integer PCM and 32-bit IEEE float (mono / stereo) are
    /// accepted.
    case unsupportedWavFormat(reason: String)
}
```

- [ ] **Step 5: Write `WavPcmReader`**

Create `Sources/SheetMusicAudioCore/Metronome/WavPcmReader.swift`:

```swift
import Foundation

/// Reads a PCM WAV container into mono `Int16` samples plus its sample rate.
///
/// Supported: 16-bit integer PCM (`audioFormat == 1`) and 32-bit IEEE
/// float (`audioFormat == 3`), mono or stereo. Stereo is down-mixed to
/// mono by averaging the channels. Anything else throws
/// `MetronomeClickError`.
///
/// Operates on raw `Data` so the Android JNI path can pass WAV bytes
/// directly (Android assets are not real file paths); a URL convenience
/// reads the file first.
public enum WavPcmReader {
    public struct Result: Equatable, Sendable {
        public let samples: [Int16]
        public let sampleRate: UInt32

        public init(samples: [Int16], sampleRate: UInt32) {
            self.samples = samples
            self.sampleRate = sampleRate
        }
    }

    public static func read(contentsOf url: URL) throws -> Result {
        try read(Data(contentsOf: url))
    }

    public static func read(_ data: Data) throws -> Result {
        let bytes = [UInt8](data)

        func u16(_ i: Int) -> UInt16 {
            UInt16(bytes[i]) | (UInt16(bytes[i + 1]) << 8)
        }
        func u32(_ i: Int) -> UInt32 {
            UInt32(bytes[i]) | (UInt32(bytes[i + 1]) << 8)
                | (UInt32(bytes[i + 2]) << 16) | (UInt32(bytes[i + 3]) << 24)
        }
        func tag(_ i: Int) -> String {
            String(bytes: bytes[i ..< i + 4], encoding: .ascii) ?? ""
        }

        guard bytes.count >= 12, tag(0) == "RIFF", tag(8) == "WAVE" else {
            throw MetronomeClickError.invalidWav(reason: "missing RIFF/WAVE header")
        }

        var format: (audioFormat: UInt16, channels: UInt16,
                     sampleRate: UInt32, bits: UInt16)?
        var dataRange: Range<Int>?

        // Walk the chunk list after the 12-byte RIFF/WAVE header. Each
        // chunk is a 4-byte id + u32 size + payload, word-aligned (odd
        // sizes are padded by one byte).
        var i = 12
        while i + 8 <= bytes.count {
            let id = tag(i)
            let size = Int(u32(i + 4))
            let payloadStart = i + 8
            guard payloadStart + size <= bytes.count else { break }
            if id == "fmt ", size >= 16 {
                format = (u16(payloadStart), u16(payloadStart + 2),
                          u32(payloadStart + 4), u16(payloadStart + 14))
            } else if id == "data" {
                dataRange = payloadStart ..< (payloadStart + size)
            }
            i = payloadStart + size + (size & 1)
        }

        guard let f = format else {
            throw MetronomeClickError.invalidWav(reason: "no fmt chunk")
        }
        guard let range = dataRange else {
            throw MetronomeClickError.invalidWav(reason: "no data chunk")
        }
        let channels = Int(f.channels)
        guard channels == 1 || channels == 2 else {
            throw MetronomeClickError.unsupportedWavFormat(
                reason: "channel count \(channels) not supported",
            )
        }

        let payload = Array(bytes[range])
        switch (f.audioFormat, f.bits) {
        case (1, 16):
            return Result(samples: decode16(payload, channels: channels),
                          sampleRate: f.sampleRate)
        case (3, 32):
            return Result(samples: decodeFloat32(payload, channels: channels),
                          sampleRate: f.sampleRate)
        default:
            throw MetronomeClickError.unsupportedWavFormat(
                reason: "audioFormat \(f.audioFormat), \(f.bits)-bit not supported",
            )
        }
    }

    private static func decode16(_ p: [UInt8], channels: Int) -> [Int16] {
        let frameBytes = 2 * channels
        let frameCount = p.count / frameBytes
        var out = [Int16]()
        out.reserveCapacity(frameCount)
        func s16(_ i: Int) -> Int16 {
            Int16(bitPattern: UInt16(p[i]) | (UInt16(p[i + 1]) << 8))
        }
        for f in 0 ..< frameCount {
            let base = f * frameBytes
            if channels == 1 {
                out.append(s16(base))
            } else {
                let mixed = (Int(s16(base)) + Int(s16(base + 2))) / 2
                out.append(Int16(mixed))
            }
        }
        return out
    }

    private static func decodeFloat32(_ p: [UInt8], channels: Int) -> [Int16] {
        let frameBytes = 4 * channels
        let frameCount = p.count / frameBytes
        var out = [Int16]()
        out.reserveCapacity(frameCount)
        func f32(_ i: Int) -> Float {
            let bits = UInt32(p[i]) | (UInt32(p[i + 1]) << 8)
                | (UInt32(p[i + 2]) << 16) | (UInt32(p[i + 3]) << 24)
            return Float(bitPattern: bits)
        }
        func toI16(_ x: Float) -> Int16 {
            let clamped = max(-1.0, min(1.0, x))
            return Int16((clamped * 32767.0).rounded())
        }
        for f in 0 ..< frameCount {
            let base = f * frameBytes
            if channels == 1 {
                out.append(toI16(f32(base)))
            } else {
                out.append(toI16((f32(base) + f32(base + 4)) / 2))
            }
        }
        return out
    }
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `swift test --filter WavPcmReaderTests`
Expected: PASS (5 tests).

- [ ] **Step 7: Commit**

```bash
git add Sources/SheetMusicAudioCore/Metronome/MetronomeClickError.swift Sources/SheetMusicAudioCore/Metronome/WavPcmReader.swift Tests/SheetMusicTests/Metronome/WavTestSupport.swift Tests/SheetMusicTests/Metronome/WavPcmReaderTests.swift
git commit -m "feat(audio-core): add WAV PCM reader (16-bit / 32-bit float, mono/stereo)"
```

---

## Task 3: `ClickSoundFontBuilder`

**Files:**
- Create: `Sources/SheetMusicAudioCore/Metronome/ClickSoundFontBuilder.swift`
- Create: `Tests/SheetMusicTests/Metronome/Sf2TestSupport.swift`
- Test: `Tests/SheetMusicTests/Metronome/ClickSoundFontBuilderTests.swift`

- [ ] **Step 1: Write the SF2 chunk-walker (test support)**

Create `Tests/SheetMusicTests/Metronome/Sf2TestSupport.swift`:

```swift
import Foundation

/// A tiny RIFF reader used only by the SF2 builder tests. Locates LIST
/// sub-lists and their subchunks so tests can assert structure without a
/// full SF2 parser.
enum Sf2TestSupport {
    static func u16(_ d: Data, _ i: Int) -> UInt16 {
        let b = [UInt8](d)
        return UInt16(b[i]) | (UInt16(b[i + 1]) << 8)
    }

    static func u32(_ d: Data, _ i: Int) -> UInt32 {
        let b = [UInt8](d)
        return UInt32(b[i]) | (UInt32(b[i + 1]) << 8)
            | (UInt32(b[i + 2]) << 16) | (UInt32(b[i + 3]) << 24)
    }

    static func tag(_ d: Data, _ i: Int) -> String {
        let b = [UInt8](d)
        return String(bytes: b[i ..< i + 4], encoding: .ascii) ?? ""
    }

    /// Find a LIST chunk whose form type matches `listType` (e.g. "pdta")
    /// and return the byte range of its inner payload (after the 4-byte
    /// form type). Searches only the top-level RIFF body.
    static func listPayloadRange(_ d: Data, listType: String) -> Range<Int>? {
        // Top-level: "RIFF" u32 size "sfbk" then LIST chunks.
        var i = 12
        let count = d.count
        while i + 8 <= count {
            let id = tag(d, i)
            let size = Int(u32(d, i + 4))
            let payloadStart = i + 8
            guard payloadStart + size <= count else { break }
            if id == "LIST", tag(d, payloadStart) == listType {
                return (payloadStart + 4) ..< (payloadStart + size)
            }
            i = payloadStart + size + (size & 1)
        }
        return nil
    }

    /// Within `range`, find a subchunk by id and return its payload range.
    static func subchunkPayloadRange(
        _ d: Data, in range: Range<Int>, id wanted: String,
    ) -> Range<Int>? {
        var i = range.lowerBound
        while i + 8 <= range.upperBound {
            let id = tag(d, i)
            let size = Int(u32(d, i + 4))
            let payloadStart = i + 8
            guard payloadStart + size <= range.upperBound else { break }
            if id == wanted {
                return payloadStart ..< (payloadStart + size)
            }
            i = payloadStart + size + (size & 1)
        }
        return nil
    }
}
```

- [ ] **Step 2: Write the failing builder test**

Create `Tests/SheetMusicTests/Metronome/ClickSoundFontBuilderTests.swift`:

```swift
@testable import SheetMusicAudioCore
import Foundation
import Testing

@Suite struct ClickSoundFontBuilderTests {
    private func sampleSf2() -> Data {
        let strong = [Int16](repeating: 1000, count: 10)
        let weak = [Int16](repeating: -1000, count: 20)
        return ClickSoundFontBuilder.build(
            strong: strong, strongRate: 44100, weak: weak, weakRate: 22050,
        )
    }

    @Test func hasRiffSfbkHeader() {
        let sf2 = sampleSf2()
        #expect(Sf2TestSupport.tag(sf2, 0) == "RIFF")
        #expect(Sf2TestSupport.tag(sf2, 8) == "sfbk")
        // Declared RIFF size matches the bytes after the 8-byte RIFF
        // header.
        #expect(Int(Sf2TestSupport.u32(sf2, 4)) == sf2.count - 8)
    }

    @Test func smplChunkHoldsBothSamplesPlusGuards() {
        let sf2 = sampleSf2()
        let sdta = Sf2TestSupport.listPayloadRange(sf2, listType: "sdta")
        #expect(sdta != nil)
        let smpl = Sf2TestSupport.subchunkPayloadRange(sf2, in: sdta!, id: "smpl")
        #expect(smpl != nil)
        // (10 strong + 46 guard + 20 weak + 46 guard) sample points * 2 bytes.
        #expect(smpl!.count == (10 + 46 + 20 + 46) * 2)
    }

    @Test func presetIsBank128() {
        let sf2 = sampleSf2()
        let pdta = Sf2TestSupport.listPayloadRange(sf2, listType: "pdta")!
        let phdr = Sf2TestSupport.subchunkPayloadRange(sf2, in: pdta, id: "phdr")!
        // First phdr record: name[20], wPreset (u16), wBank (u16) ...
        let bank = Sf2TestSupport.u16(sf2, phdr.lowerBound + 22)
        #expect(bank == 128)
    }

    @Test func hasTwoSampleHeadersPlusTerminal() {
        let sf2 = sampleSf2()
        let pdta = Sf2TestSupport.listPayloadRange(sf2, listType: "pdta")!
        let shdr = Sf2TestSupport.subchunkPayloadRange(sf2, in: pdta, id: "shdr")!
        // 46 bytes per sample header; 2 real + 1 terminal.
        #expect(shdr.count == 46 * 3)
        // First sample header's sample rate field (after 20-byte name +
        // 4 u32 offsets = offset 36).
        let strongRate = Sf2TestSupport.u32(sf2, shdr.lowerBound + 36)
        #expect(strongRate == 44100)
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter ClickSoundFontBuilderTests`
Expected: FAIL — "cannot find 'ClickSoundFontBuilder' in scope".

- [ ] **Step 4: Write `ClickSoundFontBuilder`**

Create `Sources/SheetMusicAudioCore/Metronome/ClickSoundFontBuilder.swift`:

```swift
import Foundation

/// Builds a minimal SoundFont 2 (.sf2) in memory that maps two click
/// samples to GM-percussion notes 76 (strong) and 77 (weak) in a
/// bank-128 preset.
///
/// AUMIDISynth (Apple) and FluidSynth (Android) both auto-select bank 128
/// on MIDI channel 9, and the metronome track already emits notes 76/77
/// on channel 9, so these samples are driven by the unchanged track.
///
/// The SF2 2.x layout produced here:
/// `RIFF 'sfbk'` → `LIST 'INFO'` (ifil/isng/INAM) + `LIST 'sdta'` (smpl)
/// + `LIST 'pdta'` (phdr/pbag/pmod/pgen/inst/ibag/imod/igen/shdr, each
/// section terminated by the spec's sentinel record).
public enum ClickSoundFontBuilder {
    /// Zero sample-points of guard the SF2 spec mandates after each
    /// sample's data.
    private static let guardSamples = 46

    public static func build(
        strong: [Int16], strongRate: UInt32,
        weak: [Int16], weakRate: UInt32,
    ) -> Data {
        // sdta layout (sample points): [strong][46 zeros][weak][46 zeros].
        let strongStart = 0
        let strongEnd = strong.count
        let weakStart = strongEnd + guardSamples
        let weakEnd = weakStart + weak.count

        var smpl = LittleEndianWriter()
        for s in strong { smpl.appendInt16(s) }
        for _ in 0 ..< guardSamples { smpl.appendInt16(0) }
        for s in weak { smpl.appendInt16(s) }
        for _ in 0 ..< guardSamples { smpl.appendInt16(0) }

        var info = LittleEndianWriter()
        info.append(subchunk("ifil", versionTag(major: 2, minor: 1)))
        info.append(subchunk("isng", zstr("EMU8000")))
        info.append(subchunk("INAM", zstr("SheetMusic Metronome")))

        var sdta = LittleEndianWriter()
        sdta.append(subchunk("smpl", smpl.data))

        var pdta = LittleEndianWriter()
        pdta.append(subchunk("phdr", buildPHDR()))
        pdta.append(subchunk("pbag", buildPBAG()))
        pdta.append(subchunk("pmod", terminalMOD()))
        pdta.append(subchunk("pgen", buildPGEN()))
        pdta.append(subchunk("inst", buildINST()))
        pdta.append(subchunk("ibag", buildIBAG()))
        pdta.append(subchunk("imod", terminalMOD()))
        pdta.append(subchunk("igen", buildIGEN()))
        pdta.append(subchunk("shdr", buildSHDR(
            strongStart: strongStart, strongEnd: strongEnd, strongRate: strongRate,
            weakStart: weakStart, weakEnd: weakEnd, weakRate: weakRate,
        )))

        var body = LittleEndianWriter()
        body.appendTag("sfbk")
        body.append(listChunk("INFO", info.data))
        body.append(listChunk("sdta", sdta.data))
        body.append(listChunk("pdta", pdta.data))

        var riff = LittleEndianWriter()
        riff.appendTag("RIFF")
        riff.appendUInt32(UInt32(body.data.count))
        riff.append(body.data)
        return riff.data
    }

    // MARK: - Chunk helpers

    /// 4-byte id + u32 size + payload, padded to even length.
    private static func subchunk(_ id: String, _ payload: Data) -> Data {
        var w = LittleEndianWriter()
        w.appendTag(id)
        w.appendUInt32(UInt32(payload.count))
        w.append(payload)
        if payload.count & 1 == 1 { w.appendUInt8(0) }
        return w.data
    }

    /// A LIST chunk: "LIST" size form-type + payload.
    private static func listChunk(_ type: String, _ payload: Data) -> Data {
        var inner = LittleEndianWriter()
        inner.appendTag(type)
        inner.append(payload)
        return subchunk("LIST", inner.data)
    }

    private static func versionTag(major: UInt16, minor: UInt16) -> Data {
        var w = LittleEndianWriter()
        w.appendUInt16(major)
        w.appendUInt16(minor)
        return w.data
    }

    /// Null-terminated, even-length ASCII string.
    private static func zstr(_ s: String) -> Data {
        var bytes = Array(s.utf8)
        bytes.append(0)
        if bytes.count & 1 == 1 { bytes.append(0) }
        return Data(bytes)
    }

    // MARK: - pdta sections (each ends with a sentinel record)

    /// 38-byte preset headers: our preset + terminal "EOP".
    private static func buildPHDR() -> Data {
        var w = LittleEndianWriter()
        w.appendFixedString("Click", length: 20)
        w.appendUInt16(0)    // wPreset
        w.appendUInt16(128)  // wBank (GM percussion)
        w.appendUInt16(0)    // wPresetBagNdx → first pbag
        w.appendUInt32(0)    // dwLibrary
        w.appendUInt32(0)    // dwGenre
        w.appendUInt32(0)    // dwMorphology
        // Terminal record.
        w.appendFixedString("EOP", length: 20)
        w.appendUInt16(0)
        w.appendUInt16(0)
        w.appendUInt16(1)    // one past the last real pbag
        w.appendUInt32(0)
        w.appendUInt32(0)
        w.appendUInt32(0)
        return w.data
    }

    /// 4-byte preset bags: one zone + terminal.
    private static func buildPBAG() -> Data {
        var w = LittleEndianWriter()
        w.appendUInt16(0)    // wGenNdx → first pgen
        w.appendUInt16(0)    // wModNdx
        w.appendUInt16(1)    // terminal: one past the last real pgen
        w.appendUInt16(0)
        return w.data
    }

    /// 4-byte preset generators: one "instrument" generator + terminal.
    private static func buildPGEN() -> Data {
        var w = LittleEndianWriter()
        w.appendUInt16(41)   // sfGenOper = instrument
        w.appendUInt16(0)    // instrument index 0
        w.appendUInt16(0)    // terminal
        w.appendUInt16(0)
        return w.data
    }

    /// 10-byte modulator: a single all-zero terminal record (no modulators).
    private static func terminalMOD() -> Data {
        Data(repeating: 0, count: 10)
    }

    /// 22-byte instrument headers: our instrument + terminal "EOI".
    private static func buildINST() -> Data {
        var w = LittleEndianWriter()
        w.appendFixedString("Click", length: 20)
        w.appendUInt16(0)    // wInstBagNdx → first ibag
        w.appendFixedString("EOI", length: 20)
        w.appendUInt16(2)    // one past the last real ibag
        return w.data
    }

    /// 4-byte instrument bags: zone 0 (igen 0), zone 1 (igen 4), terminal (igen 8).
    private static func buildIBAG() -> Data {
        var w = LittleEndianWriter()
        w.appendUInt16(0); w.appendUInt16(0)
        w.appendUInt16(4); w.appendUInt16(0)
        w.appendUInt16(8); w.appendUInt16(0)
        return w.data
    }

    /// 4-byte instrument generators for both zones + terminal. The last
    /// generator in each zone must be `sampleID` (53).
    private static func buildIGEN() -> Data {
        var w = LittleEndianWriter()
        func keyRangeAmount(_ lo: UInt16, _ hi: UInt16) -> UInt16 { lo | (hi << 8) }
        // Zone 0: strong → key 76, sample 0.
        w.appendUInt16(43); w.appendUInt16(keyRangeAmount(76, 76)) // keyRange
        w.appendUInt16(58); w.appendUInt16(76)                     // overridingRootKey
        w.appendUInt16(54); w.appendUInt16(0)                      // sampleModes = no loop
        w.appendUInt16(53); w.appendUInt16(0)                      // sampleID 0 (last)
        // Zone 1: weak → key 77, sample 1.
        w.appendUInt16(43); w.appendUInt16(keyRangeAmount(77, 77))
        w.appendUInt16(58); w.appendUInt16(77)
        w.appendUInt16(54); w.appendUInt16(0)
        w.appendUInt16(53); w.appendUInt16(1)
        // Terminal.
        w.appendUInt16(0); w.appendUInt16(0)
        return w.data
    }

    /// 46-byte sample headers: strong, weak, terminal "EOS".
    private static func buildSHDR(
        strongStart: Int, strongEnd: Int, strongRate: UInt32,
        weakStart: Int, weakEnd: Int, weakRate: UInt32,
    ) -> Data {
        var w = LittleEndianWriter()
        func sample(_ name: String, start: Int, end: Int, rate: UInt32, key: UInt8) {
            w.appendFixedString(name, length: 20)
            w.appendUInt32(UInt32(start))  // dwStart
            w.appendUInt32(UInt32(end))    // dwEnd
            w.appendUInt32(UInt32(start))  // dwStartloop (ignored, no loop)
            w.appendUInt32(UInt32(end))    // dwEndloop
            w.appendUInt32(rate)           // dwSampleRate
            w.appendUInt8(key)             // byOriginalPitch
            w.appendUInt8(0)               // chPitchCorrection
            w.appendUInt16(0)              // wSampleLink
            w.appendUInt16(1)              // sfSampleType = monoSample
        }
        sample("Click_Strong", start: strongStart, end: strongEnd, rate: strongRate, key: 76)
        sample("Click_Weak", start: weakStart, end: weakEnd, rate: weakRate, key: 77)
        // Terminal "EOS" record (all-zero numeric fields).
        w.appendFixedString("EOS", length: 20)
        w.appendUInt32(0); w.appendUInt32(0); w.appendUInt32(0)
        w.appendUInt32(0); w.appendUInt32(0)
        w.appendUInt8(0); w.appendUInt8(0); w.appendUInt16(0); w.appendUInt16(0)
        return w.data
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter ClickSoundFontBuilderTests`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/SheetMusicAudioCore/Metronome/ClickSoundFontBuilder.swift Tests/SheetMusicTests/Metronome/Sf2TestSupport.swift Tests/SheetMusicTests/Metronome/ClickSoundFontBuilderTests.swift
git commit -m "feat(audio-core): add click SoundFont builder (WAV PCM -> SF2)"
```

---

## Task 4: Apple synth-load validation (proves the SF2 is playable)

This is the critical Phase-1 validation: load the generated SF2 into a real
Apple sampler and render note 76 offline, asserting the output is not silent.
If this fails, the SF2 byte layout from Task 3 is wrong and must be fixed
before Phases 2/3 build on it.

**Files:**
- Test: `Tests/SheetMusicTests/Metronome/ClickSoundFontSynthLoadTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/Metronome/ClickSoundFontSynthLoadTests.swift`:

```swift
#if !os(Android)
@testable import SheetMusicAudioCore
import AVFoundation
import Foundation
import Testing

@Suite struct ClickSoundFontSynthLoadTests {
    /// Build a click SF2 with audibly non-zero samples, load it into an
    /// AVAudioUnitSampler (percussion bank), and offline-render note 76 —
    /// the strong click. A non-silent buffer proves the SF2 parsed and the
    /// note-to-sample mapping resolved.
    @Test func generatedSoundFontRendersNote76() throws {
        // ~50 ms square-ish wave at 44.1 kHz so there is real energy.
        let count = 2205
        let strong = (0 ..< count).map { i -> Int16 in
            i % 2 == 0 ? 12000 : -12000
        }
        let sf2 = ClickSoundFontBuilder.build(
            strong: strong, strongRate: 44100, weak: strong, weakRate: 44100,
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("click-\(UUID().uuidString).sf2")
        try sf2.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let engine = AVAudioEngine()
        let sampler = AVAudioUnitSampler()
        engine.attach(sampler)
        engine.connect(sampler, to: engine.mainMixerNode, format: nil)

        // SF2 bank 128 maps to AUSampler's percussion bank MSB (0x78).
        try sampler.loadSoundBankInstrument(
            at: url,
            program: 0,
            bankMSB: UInt8(kAUSampler_DefaultPercussionBankMSB),
            bankLSB: 0,
        )

        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        try engine.enableManualRenderingMode(
            .offline, format: format, maximumFrameCount: 4096,
        )
        try engine.start()

        sampler.startNote(76, withVelocity: 100, onChannel: 0)

        let buffer = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096,
        )!
        var peak: Float = 0
        for _ in 0 ..< 12 {
            let status = try engine.renderOffline(4096, to: buffer)
            if status == .success, let ch = buffer.floatChannelData {
                for i in 0 ..< Int(buffer.frameLength) {
                    peak = max(peak, abs(ch[0][i]))
                }
            }
        }
        engine.stop()
        engine.disableManualRenderingMode()

        #expect(peak > 0.0001)
    }
}
#endif
```

- [ ] **Step 2: Run the test**

Run: `swift test --filter ClickSoundFontSynthLoadTests`
Expected: PASS. The render produces a non-silent buffer.

If it FAILS (silent output or `loadSoundBankInstrument` throws), the SF2 from
Task 3 is malformed. Debug by comparing chunk offsets against the SF2 2.x
spec — most likely suspects: a wrong section terminal index (phdr/pbag/ibag
sentinel `wXxxNdx`), the `keyRange` generator byte order, or the `sampleID`
generator not being last in its zone. Fix `ClickSoundFontBuilder`, re-run
Task 3's structural tests, then re-run this test. Do NOT proceed to commit
until it passes.

- [ ] **Step 3: Commit**

```bash
git add Tests/SheetMusicTests/Metronome/ClickSoundFontSynthLoadTests.swift
git commit -m "test(audio-core): verify generated click SF2 plays on AVAudioUnitSampler"
```

---

## Task 5: `MetronomeClickSource` + `MetronomeClickProvider` (override seam)

The value types Phases 2 and 3 consume. Foundation-only, no platform code.

**Files:**
- Create: `Sources/SheetMusicAudioCore/Metronome/MetronomeClickSource.swift`
- Test: `Tests/SheetMusicTests/Metronome/MetronomeClickSourceTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/SheetMusicTests/Metronome/MetronomeClickSourceTests.swift`:

```swift
@testable import SheetMusicAudioCore
import Foundation
import Testing

@Suite struct MetronomeClickSourceTests {
    @Test func clickSamplesCarriesBothUrls() {
        let strong = URL(fileURLWithPath: "/tmp/strong.wav")
        let weak = URL(fileURLWithPath: "/tmp/weak.wav")
        let source = MetronomeClickSource.clickSamples(strong: strong, weak: weak)
        #expect(source == .clickSamples(strong: strong, weak: weak))
        #expect(source != .defaultGM)
    }

    @Test func providerReturnsConfiguredSource() {
        struct FixedProvider: MetronomeClickProvider {
            let source: MetronomeClickSource
            func metronomeClickSource() -> MetronomeClickSource { source }
        }
        let provider = FixedProvider(source: .defaultGM)
        #expect(provider.metronomeClickSource() == .defaultGM)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter MetronomeClickSourceTests`
Expected: FAIL — "cannot find 'MetronomeClickSource' in scope".

- [ ] **Step 3: Write the implementation**

Create `Sources/SheetMusicAudioCore/Metronome/MetronomeClickSource.swift`:

```swift
import Foundation

/// Where the metronome's click sound comes from. Supplied by the host
/// through a `MetronomeClickProvider`. Kept separate from
/// `SoundfontResolver` so adding click overrides doesn't disturb the
/// score-soundfont seam.
public enum MetronomeClickSource: Sendable, Equatable {
    /// Two WAV files (strong downbeat / weak beat). The engine converts
    /// them to an SF2 at load time via `ClickSoundFontBuilder`.
    case clickSamples(strong: URL, weak: URL)
    /// A host-supplied SoundFont, used verbatim (its bank-128 patch drives
    /// the metronome's notes 76/77).
    case soundFont(URL)
    /// Keep the current behavior: reuse the score's GM drum-kit SoundFont.
    case defaultGM
}

/// Implemented by the host to tell the engine which click sound to use.
/// Returning `.defaultGM` (or supplying no provider) preserves the legacy
/// GM drum-kit click.
public protocol MetronomeClickProvider: Sendable {
    func metronomeClickSource() -> MetronomeClickSource
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter MetronomeClickSourceTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/SheetMusicAudioCore/Metronome/MetronomeClickSource.swift Tests/SheetMusicTests/Metronome/MetronomeClickSourceTests.swift
git commit -m "feat(audio-core): add metronome click source/provider seam types"
```

---

## Task 6: Full-suite green + Android-shape check

Confirm the new files don't break the whole suite and that the Foundation-only
files still resolve under the Android manifest shape (per CLAUDE.md's
"recurring pitfalls").

- [ ] **Step 1: Run the whole test suite**

Run: `swift test`
Expected: PASS (100% green, including the new Metronome suites).

- [ ] **Step 2: Verify the package still describes under the Android env**

Run: `SWIFT_SHEET_MUSIC_ANDROID=1 swift package describe`
Expected: succeeds and lists `SheetMusicAudioCore`. (The new files are
Foundation-only; the AVFoundation test is `#if !os(Android)`-gated, so the
Android shape is unaffected. We are not cross-compiling here — just confirming
the manifest still resolves.)

- [ ] **Step 3: Lint (if available)**

Run: `swiftlint --quiet Sources/SheetMusicAudioCore Tests/SheetMusicTests/Metronome`
Expected: 0 warnings/errors. (Skip if `swiftlint` is not installed.)

- [ ] **Step 4: No commit needed**

This task only verifies; all code was committed in Tasks 1–5. If lint or the
full suite surface fixes, commit them with `style:` / `fix:` as appropriate.

---

## Self-Review

**Spec coverage (Phase 1 portion of the spec):**
- `WavPcmReader` (16-bit + 32-bit float, mono/stereo down-mix, `Data`-based, throws on unsupported) → Task 2. ✓
- `ClickSoundFontBuilder` (bank-128 preset, notes 76/77, unlooped, 46-sample guard, LE writer) → Task 3 + Task 1. ✓
- `MetronomeClickSource` / `MetronomeClickProvider` seam → Task 5. ✓
- Tests: WAV reader formats, SF2 structure, Apple synth-load non-silence, (round-trip/backward-compat live in Phase 2/3 where the engine is wired). ✓ for the Core-testable subset.
- Out of scope here (correctly deferred): Apple `MetronomeController`/export wiring (Phase 2), Android JNI + Kotlin wiring (Phase 3), caching of the generated SF2 file (lives in the platform integration that owns the file lifecycle).

**Placeholder scan:** No TBD/TODO; every code step has complete code and exact commands. ✓

**Type consistency:** `LittleEndianWriter` methods (`appendUInt8/appendUInt16/appendInt16/appendUInt32/appendTag/appendFixedString/append/data`) are used identically in Tasks 1 and 3. `WavPcmReader.Result(samples:sampleRate:)`, `WavPcmReader.read(_:)`, `MetronomeClickError` cases, `ClickSoundFontBuilder.build(strong:strongRate:weak:weakRate:)`, and `MetronomeClickSource` cases match across their definition and test call sites. ✓

**Note for the implementer:** Task 4 is a real verification gate, not a formality — the SF2 byte layout is the riskiest part of the whole feature. If Task 4 can't be made to pass after reasonable debugging, STOP and report rather than weakening the assertion.
