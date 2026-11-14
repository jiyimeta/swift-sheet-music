import Foundation
import SheetMusicAudioCore
@testable import SheetMusicAudioWindows
import Testing

/// `MediaFoundationAudio`: files this package writes itself (a WAV through `PCMFileSink`, an AAC M4A through
/// `AACFileSink`, a silent H.264 MP4 through `MP4VideoWriter`), probed and decoded back. The M4A carries a click at a
/// known frame, so the decode shows where Media Foundation puts the encoder's priming. Only where Media Foundation
/// loads (not on an "N" edition without the Media Feature Pack).
@Suite(.enabled(if: MediaFoundationAudio.isDecoderAvailable))
struct MediaFoundationAudioTests {
    private static func temporaryPath(_ suffix: String) -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("ssm-mfa-\(UUID().uuidString)\(suffix)").path
    }

    /// Interleaved stereo float: a ramp on the left, its negation on the right, so an exact 16-bit round trip and the
    /// channel order both show.
    private static func ramp(frames: Int) -> [Float] {
        var samples = [Float](repeating: 0, count: frames * 2)
        for frame in 0 ..< frames {
            let value = Float(frame % 2000 - 1000) / 2048
            samples[2 * frame] = value
            samples[2 * frame + 1] = -value
        }
        return samples
    }

    private static func writeWAV(at path: String, frames: Int, rate: Double = 44100) throws {
        let sink = try PCMFileSink(
            url: URL(fileURLWithPath: path), options: PCMOptions(sampleRate: rate, bitDepth: .int16, channels: .stereo),
            encoding: .wav,
        )
        let samples = ramp(frames: frames)
        try samples.withUnsafeBufferPointer { try sink.append($0, frames: frames) }
        try sink.finish()
    }

    private static func readInt16(_ path: String) throws -> [Int16] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    @Test
    func `a WAV probes as read and decodes to the same samples`() throws {
        let wav = Self.temporaryPath(".wav")
        let pcm = Self.temporaryPath(".pcm16")
        defer {
            try? FileManager.default.removeItem(atPath: wav)
            try? FileManager.default.removeItem(atPath: pcm)
        }
        let frames = 44100
        try Self.writeWAV(at: wav, frames: frames)

        let probe = MediaFoundationAudio.probe(path: wav)
        #expect(probe.status == .read)
        #expect(!probe.isAACLC)
        #expect(probe.sampleRate == 44100 && probe.channels == 2)
        #expect(abs(probe.durationSeconds - 1) < 0.01, "duration \(probe.durationSeconds) s")

        let decoded = try MediaFoundationAudio.decodePCM16(sourcePath: wav, outputPath: pcm)
        #expect(decoded.sampleRate == 44100 && decoded.channels == 2 && decoded.frames == Int64(frames))
        let samples = try Self.readInt16(pcm)
        let expected = Self.ramp(frames: frames).map { Int16(($0 * 32767).rounded()) }
        #expect(samples.count == expected.count)
        let mismatches = zip(samples, expected).count(where: { abs(Int($0) - Int($1)) > 1 })
        #expect(mismatches == 0, "\(mismatches) samples differ by more than one step")
    }

    @Test
    func `a WAV decodes into a PCM cache file playback maps`() throws {
        let wav = Self.temporaryPath(".wav")
        let directory = Self.temporaryPath("")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: wav)
            try? FileManager.default.removeItem(atPath: directory)
        }
        try Self.writeWAV(at: wav, frames: 24000, rate: 48000)

        let (path, decoded) = try MediaFoundationAudio.decodeRecordingCache(
            sourcePath: wav, directory: directory, cacheKey: "track",
        )
        #expect(decoded.frames == 24000 && decoded.sampleRate == 48000)
        let existing = RecordingPCMCacheWriter.existingFile(directory: directory, cacheKey: "track", sampleRate: 48000)
        #expect(existing == path)
        // Mapped with CreateFileMapping: the frames read back as written, and asking for pages ahead is harmless.
        let recording = try MappedRecording(path: path)
        #expect(abs(recording.durationSeconds - 0.5) < 1e-9)
        recording.prefetch(seconds: 0 ..< 0.25)
        let frames = recording.frames
        let expected = Self.ramp(frames: 24000).map { Int16(($0 * 32767).rounded()) }
        #expect(abs(Int(frames.base[2 * 1234]) - Int(expected[2 * 1234])) <= 1)
        #expect(abs(Int(frames.base[2 * 23999 + 1]) - Int(expected[2 * 23999 + 1])) <= 1)
    }

    /// Where the click written at frame `clickFrame` of an AAC M4A lands in its decode: the frames of encoder priming
    /// Media Foundation's reader leaves in (0 when it honours the file's edit list) — the constant a host would trim
    /// by, as Android's `AudioPriming` does. Measured on folino-win 2026-11-15: 0 frames, the reader trims Media
    /// Foundation's own encoder priming, and ends 128 frames long (padding). Held to that, so a Windows update that
    /// changes it fails.
    @Test
    func `an AAC M4A probes as AAC-LC, and the decode keeps the click near where it was written`() throws {
        let m4a = Self.temporaryPath(".m4a")
        let pcm = Self.temporaryPath(".pcm16")
        defer {
            try? FileManager.default.removeItem(atPath: m4a)
            try? FileManager.default.removeItem(atPath: pcm)
        }
        let rate = 48000
        let frames = rate
        let clickFrame = 24000
        let options = CompressedOptions(sampleRate: Double(rate), bitRate: 128_000, channels: .stereo)
        let sink = try AACFileSink(url: URL(fileURLWithPath: m4a), options: options, format: .m4a(options))
        var samples = [Float](repeating: 0, count: frames * 2)
        for frame in clickFrame ..< clickFrame + 48 {
            samples[2 * frame] = 0.8
            samples[2 * frame + 1] = 0.8
        }
        try samples.withUnsafeBufferPointer { try sink.append($0, frames: frames) }
        try sink.finish()

        let probe = MediaFoundationAudio.probe(path: m4a)
        #expect(probe.status == .read)
        #expect(probe.isAACLC)
        #expect(probe.sampleRate == rate && probe.channels == 2)
        #expect(probe.bitRate > 64000 && probe.bitRate < 256_000, "bit rate \(probe.bitRate)")

        let decoded = try MediaFoundationAudio.decodePCM16(sourcePath: m4a, outputPath: pcm)
        #expect(decoded.sampleRate == rate && decoded.channels == 2)
        let left = try Self.readInt16(pcm).enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
        let onset = try #require(left.firstIndex(where: { abs(Int($0)) > 8000 }), "no click in the decode")
        let shift = onset - clickFrame
        print("MediaFoundationAudioTests: AAC click at \(clickFrame) decodes at \(onset) (shift \(shift) frames), "
            + "\(decoded.frames) frames decoded of \(frames) written, "
            + "first block at \(decoded.firstBlockStartSeconds) s")
        // Within a few frames: AAC smears an impulse, so the first sample past the threshold can move by one or two.
        #expect(abs(shift) <= 8, "the click moved \(shift) frames")
    }

    @Test
    func `a video with no sound probes as having no audio track`() throws {
        let mp4 = Self.temporaryPath(".mp4")
        defer { try? FileManager.default.removeItem(atPath: mp4) }
        guard MP4VideoWriter.isAvailable else { return }
        let writer = try MP4VideoWriter(
            url: URL(fileURLWithPath: mp4), width: 64, height: 64, fps: 10, videoBitRate: 500_000, audio: nil,
        )
        let frame = [UInt8](repeating: 128, count: 64 * 64 * 4)
        for _ in 0 ..< 10 {
            try frame.withUnsafeBytes { try writer.appendFrame($0) }
        }
        try writer.finish()
        #expect(MediaFoundationAudio.probe(path: mp4).status == .noAudioTrack)
        #expect(throws: MediaFoundationAudio.Failure.self) {
            try MediaFoundationAudio.decodePCM16(sourcePath: mp4, outputPath: Self.temporaryPath(".pcm16"))
        }
    }

    @Test
    func `a file that is not media probes as unreadable and does not decode`() throws {
        let junk = Self.temporaryPath(".m4a")
        defer { try? FileManager.default.removeItem(atPath: junk) }
        try Data((0 ..< 4096).map { UInt8($0 % 251) }).write(to: URL(fileURLWithPath: junk))
        #expect(MediaFoundationAudio.probe(path: junk).status == .unreadable)
        #expect(MediaFoundationAudio.probe(path: Self.temporaryPath(".m4a")).status == .unreadable)
        #expect(throws: MediaFoundationAudio.Failure.self) {
            try MediaFoundationAudio.decodePCM16(sourcePath: junk, outputPath: Self.temporaryPath(".pcm16"))
        }
    }
}
