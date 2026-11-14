import Foundation
import SheetMusicAudioCore
@_spi(PlaybackProbe) @testable import SheetMusicAudioWindows
import SheetMusicCore
import Testing

/// Recordings through `WindowsPlaybackEngine`'s render (`HostedSynth.renderMix`), pulled offline with no SoundFont,
/// so the only sound is the recording: where its impulses land with and without a warp, what the clocks report
/// under one, how long a count-in into a slowed measure lasts, and a tone at 70 % keeping its pitch through
/// Signalsmith. The score is `CountInTransportTests.score()`: 4/4 quarters at 120 bpm, 960 ticks a second.
struct RecordingPlaybackTests {
    static let sampleRate = CountInTransportTests.sampleRate

    /// A PCM cache file in a fresh directory, from `samples(frame)` for `seconds` at the engine's rate.
    static func recording(seconds: Double, _ sample: (Int) -> Int16) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ssm-rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let writer = try RecordingPCMCacheWriter(directory: directory.path, cacheKey: "fixture", sampleRate: sampleRate)
        let frames = Int(seconds * sampleRate)
        var block = [Int16](repeating: 0, count: 2 * 4096)
        var done = 0
        while done < frames {
            let count = min(4096, frames - done)
            for index in 0 ..< count {
                let value = sample(done + index)
                block[2 * index] = value
                block[2 * index + 1] = value
            }
            try writer.append(interleavedStereo: block, frameCount: count)
            done += count
        }
        return try URL(fileURLWithPath: writer.finish())
    }

    /// One-frame impulses at `seconds`.
    static func impulses(at seconds: [Double], length: Double) throws -> URL {
        let frames = Set(seconds.map { Int(($0 * sampleRate).rounded()) })
        return try recording(seconds: length) { frames.contains($0) ? 20000 : 0 }
    }

    static func wholeRecording(_ seconds: Double) -> [RecordingSegment] {
        [RecordingSegment(sourceStart: 0, sourceEnd: seconds, outputStart: 0)]
    }

    /// The left channel of `seconds` of the engine's render, pulled in 4096-frame callbacks.
    static func render(_ engine: WindowsPlaybackEngine, seconds: Double) -> [Float] {
        let frames = 4096
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        defer { buffer.deallocate() }
        var left: [Float] = []
        let total = Int(seconds * sampleRate)
        while left.count < total {
            _ = engine.core.renderOffline(into: buffer, frames: frames)
            for index in 0 ..< frames {
                left.append(buffer[index * 2])
            }
        }
        return left
    }

    /// The frames where the signal jumps past `threshold` after being quiet, in order.
    static func onsets(_ samples: [Float], threshold: Float = 0.05) -> [Int] {
        var found: [Int] = []
        var quietSince = 0
        for (index, sample) in samples.enumerated() where abs(sample) > threshold {
            if found.isEmpty || index - quietSince > 2000 { found.append(index) }
            quietSince = index
        }
        return found
    }

    static func engine() throws -> (WindowsPlaybackEngine, Score) {
        let score = CountInTransportTests.score()
        return try (CountInTransportTests.engine(score), score)
    }

    @Test
    func `a recording's impulses sound where they are, within 2 ms`() throws {
        let (engine, score) = try Self.engine()
        defer { engine.teardown() }
        let beats = [0.5, 1.0, 1.5, 2.0]
        let file = try Self.impulses(at: beats, length: 3)
        try engine.setRecordingTracks([RecordingTrack(id: "beats", pcmFile: file)])
        engine.setAlignment(warp: nil, segments: Self.wholeRecording(3))
        engine.play(in: score)
        let onsets = Self.onsets(Self.render(engine, seconds: 2.5))
        #expect(onsets.count == beats.count, "onsets at \(onsets)")
        for (onset, beat) in zip(onsets, beats) {
            #expect(abs(Double(onset) / Self.sampleRate - beat) < 0.002, "an impulse at \(beat) s sounded at \(onset)")
        }
    }

    /// Transport 1 s – 2 s lasts 1.25 s, so the beats at transport 0.5, 1, 1.6 and 2 s are at warped seconds 0.5, 1,
    /// 1.75 and 2.25 — where the recording has them, and where the clocks report the score.
    @Test
    func `under a warp the recording keeps its time and the clocks report both`() throws {
        let (engine, score) = try Self.engine()
        defer { engine.teardown() }
        let warp = try PlaybackTimeWarp(spans: [.init(start: 1, end: 2, duration: 1.25)])
        let beats = [0.5, 1.0, 1.75, 2.25]
        let file = try Self.impulses(at: beats, length: 3)
        try engine.setRecordingTracks([RecordingTrack(id: "beats", pcmFile: file)])
        engine.setAlignment(warp: warp, segments: Self.wholeRecording(3))
        #expect(engine.hasAlignment)
        // 8 s notated, of which one second lasts 1.25.
        #expect(abs(engine.totalTimeSeconds - 8.25) < 0.01, "total \(engine.totalTimeSeconds) s")
        engine.play(in: score)
        let onsets = Self.onsets(Self.render(engine, seconds: 2.5))
        #expect(onsets.count == beats.count, "onsets at \(onsets)")
        for (onset, beat) in zip(onsets, beats) {
            #expect(abs(Double(onset) / Self.sampleRate - beat) < 0.002, "an impulse at \(beat) s sounded at \(onset)")
        }
        // 2.5 s rendered (rounded up to whole callbacks): warped ≈ 2.5, notated ≈ 2.2.
        let warped = engine.currentTimeSecondsContinuous
        let notated = engine.notatedTimeSecondsContinuous
        #expect(abs(warped - 2.508) < 0.05, "warped \(warped) s")
        #expect(abs(notated - 2.258) < 0.05, "notated \(notated) s")
        #expect(abs(engine.notatedSeconds(forReportedSeconds: 1.75) - 1.6) < 0.01)
        #expect(abs(engine.reportedSeconds(forNotatedSeconds: 1.6) - 1.75) < 0.01)
    }

    /// The first bar's two seconds last four under the warp, so the bar's count — its own 2 s at 120 bpm — counts at
    /// half speed and lasts 4 s, as `HostedSynth.countIn` has it.
    @Test
    func `a count-in into a slowed bar counts at its speed`() throws {
        let (engine, score) = try Self.engine()
        defer { engine.teardown() }
        let warp = try PlaybackTimeWarp(spans: [.init(start: 0, end: 2, duration: 4)])
        engine.setAlignment(warp: warp, segments: Self.wholeRecording(8))
        engine.play(in: score, countIn: true)
        #expect(try #require(engine.probeTransport).countingIn)
        _ = Self.render(engine, seconds: 3.5)
        #expect(try #require(engine.probeTransport).countingIn, "the count ended before 3.5 s")
        _ = Self.render(engine, seconds: 0.8)
        #expect(try !#require(engine.probeTransport).countingIn, "the count still runs at 4.3 s")
    }

    /// The pitch of `samples` from its rising zero crossings, in Hz.
    static func pitch(_ samples: ArraySlice<Float>) -> Double {
        var crossings: [Int] = []
        var previous = samples.first ?? 0
        for (index, sample) in zip(samples.indices, samples) {
            if previous < 0, sample >= 0 { crossings.append(index) }
            previous = sample
        }
        guard let first = crossings.first, let last = crossings.last, crossings.count > 2 else { return 0 }
        return Double(crossings.count - 1) / (Double(last - first) / sampleRate)
    }

    @Test
    func `at 70 % a 440 Hz recording stays at 440 Hz`() throws {
        let (engine, score) = try Self.engine()
        defer { engine.teardown() }
        let file = try Self.recording(seconds: 4) { frame in
            Int16(12000 * sin(2 * Double.pi * 440 * Double(frame) / sampleRate))
        }
        try engine.setRecordingTracks([RecordingTrack(id: "tone", pcmFile: file)])
        engine.setAlignment(warp: nil, segments: Self.wholeRecording(4))
        engine.setRate(0.7)
        engine.play(in: score)
        let samples = Self.render(engine, seconds: 2)
        let pitch = Self.pitch(samples[Int(sampleRate) ..< Int(1.5 * sampleRate)])
        #expect(abs(pitch - 440) <= 2, "pitch at 70 %: \(pitch) Hz")
    }
}
