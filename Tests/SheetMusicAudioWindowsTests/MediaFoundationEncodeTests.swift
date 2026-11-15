import Foundation
import SheetMusicAudioCore
@testable import SheetMusicAudioWindows
import Testing

/// `MediaFoundationAudio.encodeAAC`: a WAV this package writes, encoded to AAC-LC M4A at the rate and channel count a
/// recording's import stores, then probed back; its edit list read from the file; a cancel and a refused format leave
/// no file. Only where Media Foundation loads.
@Suite(.enabled(if: MediaFoundationAudio.isDecoderAvailable))
struct MediaFoundationEncodeTests {
    private static func temporaryPath(_ suffix: String) -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("ssm-mfe-\(UUID().uuidString)\(suffix)").path
    }

    /// `seconds` of a 441 Hz stereo sine at `rate`, with a click of 48 frames at `clickFrame` when given.
    private static func writeWAV(at path: String, rate: Double, seconds: Double = 1, clickFrame: Int? = nil) throws {
        let frames = Int(rate * seconds)
        let options = PCMOptions(sampleRate: rate, bitDepth: .int16, channels: .stereo)
        let sink = try PCMFileSink(url: URL(fileURLWithPath: path), options: options, encoding: .wav)
        var samples = [Float](repeating: 0, count: frames * 2)
        if let clickFrame {
            for frame in clickFrame ..< clickFrame + 48 {
                samples[2 * frame] = 0.8
                samples[2 * frame + 1] = 0.8
            }
        } else {
            for frame in 0 ..< frames {
                let value = Float(sin(2 * Double.pi * 441 * Double(frame) / rate) * 0.5)
                samples[2 * frame] = value
                samples[2 * frame + 1] = value
            }
        }
        try samples.withUnsafeBufferPointer { try sink.append($0, frames: frames) }
        try sink.finish()
    }

    /// The first `elst` entry's media time in the file at `path`: where the edit list says the sound starts, in the
    /// track's timescale. Nil without an edit list.
    private static func editListMediaTime(_ path: String) throws -> Int64? {
        let bytes = try [UInt8](Data(contentsOf: URL(fileURLWithPath: path)))
        let tag: [UInt8] = Array("elst".utf8)
        guard let at = (0 ... bytes.count - 4).first(where: { Array(bytes[$0 ..< $0 + 4]) == tag }) else { return nil }
        func integer(_ start: Int, _ count: Int) -> Int64 {
            bytes[start ..< start + count].reduce(Int64(0)) { $0 << 8 | Int64($1) }
        }
        let version = bytes[at + 4]
        let entries = at + 12
        if version == 1 {
            return integer(entries + 8, 8)
        }
        return Int64(Int32(truncatingIfNeeded: integer(entries + 4, 4)))
    }

    @Test(arguments: [(22050.0, 48000, 2), (44100.0, 44100, 2), (48000.0, 48000, 1)])
    func `a source encodes to AAC-LC at the asked rate and channels`(source: Double, rate: Int, channels: Int) throws {
        let wav = Self.temporaryPath(".wav")
        let m4a = Self.temporaryPath(".m4a")
        defer {
            try? FileManager.default.removeItem(atPath: wav)
            try? FileManager.default.removeItem(atPath: m4a)
        }
        try Self.writeWAV(at: wav, rate: source)
        var reported: [Double] = []

        let encoded = try MediaFoundationAudio.encodeAAC(
            sourcePath: wav, outputPath: m4a, sampleRate: rate, channels: channels, bitRate: 128_000,
            progress: { reported.append($0) },
        )

        #expect(abs(encoded.frames - Int64(rate)) <= Int64(rate / 100), "\(encoded.frames) frames")
        let probe = MediaFoundationAudio.probe(path: m4a)
        #expect(probe.status == .read && probe.isAACLC)
        #expect(probe.sampleRate == rate && probe.channels == channels)
        // The second, after the leading priming (`aacEncoderPrimingFrames`) the file holds until a host states it.
        let primed = 1 + Double(MediaFoundationAudio.aacEncoderPrimingFrames) / Double(rate)
        #expect(abs(probe.durationSeconds - primed) < 0.05, "duration \(probe.durationSeconds) s")
        #expect(reported.last == 1 && zip(reported, reported.dropFirst()).allSatisfy { $0 <= $1 })
    }

    /// The encode leads with `aacEncoderPrimingFrames` of silence and states nothing itself: the sink writes no edit
    /// list, Media Foundation's reader then trims nothing, and the click decodes that much later than written —
    /// which a host's edit list takes back off (folino's `MP4PrimingEditList`). Prints what it found for the record,
    /// and keeps the file for a decode elsewhere.
    @Test
    func `the encode leads with the priming a host states`() throws {
        let wav = Self.temporaryPath(".wav")
        let m4a = Self.temporaryPath(".m4a")
        let pcm = Self.temporaryPath(".pcm16")
        defer {
            for path in [wav, m4a, pcm] {
                try? FileManager.default.removeItem(atPath: path)
            }
        }
        try Self.writeWAV(at: wav, rate: 48000, clickFrame: 24000)
        _ = try MediaFoundationAudio.encodeAAC(
            sourcePath: wav, outputPath: m4a, sampleRate: 48000, channels: 2, bitRate: 128_000,
        )
        let mediaTime = try Self.editListMediaTime(m4a)
        let decoded = try MediaFoundationAudio.decodePCM16(sourcePath: m4a, outputPath: pcm)
        let data = try Data(contentsOf: URL(fileURLWithPath: pcm))
        let left = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }.enumerated()
            .filter { $0.offset.isMultiple(of: 2) }.map(\.element)
        let onset = left.firstIndex(where: { abs(Int($0)) > 8000 })
        print("MediaFoundationEncodeTests: elst media time \(mediaTime.map(String.init) ?? "none"), "
            + "click at 24000 decodes at \(onset.map(String.init) ?? "none"), \(decoded.frames) frames decoded")
        // Kept for a decode elsewhere (AVFoundation, ffmpeg), which the priming has to be stated for.
        if let keep = ProcessInfo.processInfo.environment["SSM_KEEP_MP4_DIR"] {
            try? FileManager.default.removeItem(atPath: keep + "/encode-click-24000.m4a")
            try? FileManager.default.copyItem(atPath: m4a, toPath: keep + "/encode-click-24000.m4a")
        }
        #expect(mediaTime == nil, "Media Foundation's sink states no priming; the host does")
        let expected = 24000 + MediaFoundationAudio.aacEncoderPrimingFrames
        let found = try #require(onset, "no click in the decode")
        #expect(abs(found - expected) <= 8, "the click follows the leading silence: \(found), not \(expected)")
    }

    @Test
    func `a cancel throws and leaves no file`() throws {
        let wav = Self.temporaryPath(".wav")
        let m4a = Self.temporaryPath(".m4a")
        defer { try? FileManager.default.removeItem(atPath: wav) }
        try Self.writeWAV(at: wav, rate: 48000, seconds: 3)
        var asked = 0

        #expect(throws: MediaFoundationAudio.Failure.cancelled) {
            try MediaFoundationAudio.encodeAAC(
                sourcePath: wav, outputPath: m4a, sampleRate: 48000, channels: 2, bitRate: 128_000,
                isCancelled: {
                    asked += 1
                    return asked > 3
                },
            )
        }
        #expect(!FileManager.default.fileExists(atPath: m4a))
    }

    @Test
    func `a rate the encoder does not take is refused before a file is made`() throws {
        let wav = Self.temporaryPath(".wav")
        let m4a = Self.temporaryPath(".m4a")
        defer { try? FileManager.default.removeItem(atPath: wav) }
        try Self.writeWAV(at: wav, rate: 48000)

        #expect(throws: MediaFoundationAudio.Failure.unsupportedFormat) {
            try MediaFoundationAudio.encodeAAC(
                sourcePath: wav, outputPath: m4a, sampleRate: 32000, channels: 2, bitRate: 128_000,
            )
        }
        #expect(!FileManager.default.fileExists(atPath: m4a))
    }
}
