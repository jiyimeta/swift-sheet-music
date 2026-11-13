import Foundation
import SheetMusicAudioCore
@testable import SheetMusicAudioWindows
import SheetMusicCore
import Testing

/// `exportAudioFile(…, countIn: true)`: the count live playback plays from the start, in front of the music — the file
/// longer by the pre-roll, as the Apple engine's export is. No SoundFont: what is checked is the file's length, which a
/// silent synth renders as exactly as a sounding one.
struct ExportCountInTests {
    private static let sampleRate = 44100.0
    private let wav16 = AudioFileFormat.wav(PCMOptions(sampleRate: 44100, bitDepth: .int16, channels: .stereo))

    /// Frames in a 16-bit stereo WAV written by `WAVEncoding`: its `data` size over 4.
    private func wavFrames(_ url: URL) throws -> Int {
        let bytes = try Data(contentsOf: url)
        let size = bytes[40 ..< 44].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        return size / 4
    }

    private func export(_ score: Score, countIn: Bool, on engine: WindowsPlaybackEngine) async throws -> Int {
        let url = Fixtures.temporaryFile("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try await engine.exportAudioFile(to: url, score: score, format: wav16, countIn: countIn)
        return try wavFrames(url)
    }

    @Test
    func `a counted-in export is longer by the pre-roll`() async throws {
        let score = CountInTransportTests.score()
        let engine = try CountInTransportTests.engine(score)
        defer { engine.teardown() }
        let plain = try await export(score, countIn: false, on: engine)
        let counted = try await export(score, countIn: true, on: engine)
        let plan = try #require(CountInBeats.compute(score: score, startCursor: nil))
        let preRollSeconds = Double(plan.preRollTicks) / Double(score.division) * 60 / plan.quarterBpm
        let difference = Double(counted - plain)
        // The end is decided between two chunks, after the chunk that reached it — in each of the two files.
        #expect(
            abs(difference - preRollSeconds * Self.sampleRate) < Double(3 * PlaybackCore.chunkFrames),
            "longer by \(difference / Self.sampleRate) s, the pre-roll is \(preRollSeconds) s",
        )
        #expect(engine.state == .stopped)
    }

    /// The count-in replaces the metronome's sequence on the engine that rendered it; a plain export after it starts
    /// without one and is the plain length again.
    @Test
    func `a plain export after a counted one is not counted`() async throws {
        let score = CountInTransportTests.score()
        let engine = try CountInTransportTests.engine(score)
        defer { engine.teardown() }
        let first = try await export(score, countIn: false, on: engine)
        _ = try await export(score, countIn: true, on: engine)
        let again = try await export(score, countIn: false, on: engine)
        #expect(abs(again - first) < 3 * PlaybackCore.chunkFrames, "plain \(first) frames, then \(again)")
    }
}
