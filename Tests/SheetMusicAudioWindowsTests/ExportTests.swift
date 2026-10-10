import Foundation
import SheetMusicAudioCore
@testable import SheetMusicAudioWindows
import SheetMusicCore
import Testing

struct ExportTests {
    private let wav16 = AudioFileFormat.wav(PCMOptions(sampleRate: 44100, bitDepth: .int16, channels: .stereo))

    private func offlineEngine(_ name: String) throws -> (WindowsPlaybackEngine, Score) {
        let engine = WindowsPlaybackEngine(
            soundfontResolver: Fixtures.silentResolver, output: .offline(sampleRate: 44100),
        )
        let score = try Fixtures.score(name)
        try engine.prepare(score: score)
        return (engine, score)
    }

    /// Frames in a 16-bit stereo WAV written by `WAVEncoding`: its `data` size over 4, with the size checked against
    /// the file's.
    private func wavFrames(_ url: URL) throws -> Int {
        let bytes = try Data(contentsOf: url)
        let size = bytes[40 ..< 44].enumerated().reduce(0) { $0 | Int($1.element) << (8 * $1.offset) }
        #expect(bytes.count == 44 + size)
        return size / 4
    }

    @Test func aWAVExportIsTheScoresLength() async throws {
        let (engine, score) = try offlineEngine("multiPartMixedStaves")
        defer { engine.teardown() }
        let url = Fixtures.temporaryFile("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try await engine.exportAudioFile(to: url, score: score, format: wav16)
        let expected = engine.totalTimeSeconds * 44100
        // The end is decided between two 64-frame chunks, after the chunk that reached it, and FluidSynth rounds its
        // player's position to the millisecond.
        #expect(try abs(Double(wavFrames(url)) - expected) < Double(3 * PlaybackCore.chunkFrames))
        #expect(engine.state == .stopped)
    }

    @Test func exportLengthFollowsRepeats() async throws {
        let (engine, score) = try offlineEngine("repeat52")
        defer { engine.teardown() }
        let url = Fixtures.temporaryFile("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try await engine.exportAudioFile(to: url, score: score, format: wav16)
        // The notated length is what a render sized from the timeline would stop at; the repeats play past it.
        #expect(try Double(wavFrames(url)) > engine.totalTimeSeconds * 44100 + 4410)
    }

    @Test func progressRisesToOne() async throws {
        let (engine, score) = try offlineEngine("repeat52")
        defer { engine.teardown() }
        let url = Fixtures.temporaryFile("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let seen = Recorder()
        try await engine.exportAudioFile(to: url, score: score, format: wav16) { seen.add($0) }
        let values = seen.values
        #expect(values.last == 1)
        #expect(values == values.sorted())
    }

    /// Cancelled as it starts: a silent render is too quick to cancel midway reliably, and the flag is read before
    /// every chunk, so the first read stops it. A cancel midway, with the real SoundFont, is folino's UIA.
    @Test func cancelledExportDeletesItsFile() async throws {
        let (engine, score) = try offlineEngine("repeat52")
        defer { engine.teardown() }
        let url = Fixtures.temporaryFile("wav")
        let format = wav16
        let task = Task {
            try await engine.exportAudioFile(to: url, score: score, format: format)
        }
        task.cancel()
        await #expect(throws: AudioExportError.cancelled) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func anUnpreparedScoreIsRefused() async throws {
        let (engine, _) = try offlineEngine("multiPartMixedStaves")
        defer { engine.teardown() }
        let other = try Fixtures.score("repeat52")
        await #expect(throws: AudioExportError.noScorePrepared) {
            try await engine.exportAudioFile(to: Fixtures.temporaryFile("wav"), score: other, format: wav16)
        }
    }

    @Test func mp3IsNotWrittenHere() async throws {
        let (engine, score) = try offlineEngine("multiPartMixedStaves")
        defer { engine.teardown() }
        let format = AudioFileFormat.mp3()
        #expect(!WindowsPlaybackEngine.canExport(format))
        await #expect(throws: AudioExportError.formatUnsupportedOnThisOS(format)) {
            try await engine.exportAudioFile(to: Fixtures.temporaryFile("x"), score: score, format: format)
        }
    }

    /// An AIFF of the same render as the WAV: its `COMM` frame count and `SSND` size say the same length, and its
    /// samples are the WAV's with each sample's bytes reversed.
    @Test func anAIFFIsTheWAVBigEndian() async throws {
        let (engine, score) = try offlineEngine("multiPartMixedStaves")
        defer { engine.teardown() }
        let aiff = AudioFileFormat.aiff(PCMOptions(sampleRate: 44100, bitDepth: .int16, channels: .stereo))
        #expect(WindowsPlaybackEngine.canExport(aiff))
        let wavURL = Fixtures.temporaryFile("wav")
        let aiffURL = Fixtures.temporaryFile("aiff")
        defer {
            try? FileManager.default.removeItem(at: wavURL)
            try? FileManager.default.removeItem(at: aiffURL)
        }
        try await engine.exportAudioFile(to: wavURL, score: score, format: wav16)
        try await engine.exportAudioFile(to: aiffURL, score: score, format: aiff)
        let bytes = try [UInt8](Data(contentsOf: aiffURL))
        let bigEndian = { (offset: Int) in bytes[offset ..< offset + 4].reduce(0) { $0 << 8 | Int($1) } }
        #expect(Array(bytes[0 ..< 4]) == Array("FORM".utf8))
        #expect(bigEndian(4) == bytes.count - 8)
        #expect(Array(bytes[8 ..< 12]) == Array("AIFF".utf8))
        let frames = try wavFrames(wavURL)
        #expect(bigEndian(22) == frames)
        #expect(bigEndian(42) == 8 + frames * 4)
        let wav = try [UInt8](Data(contentsOf: wavURL))
        #expect(bytes.count - 54 == wav.count - 44)
        for sample in [0, 1, frames / 2, frames * 2 - 1] {
            #expect(bytes[54 + sample * 2] == wav[44 + sample * 2 + 1], "sample \(sample)")
            #expect(bytes[54 + sample * 2 + 1] == wav[44 + sample * 2], "sample \(sample)")
        }
    }

    @Test func anM4AIsAnMPEG4File() async throws {
        let format = AudioFileFormat.m4a(CompressedOptions(sampleRate: 44100, bitRate: 128_000, channels: .stereo))
        try #require(WindowsPlaybackEngine.canExport(format), "no AAC encoder on this Windows")
        let (engine, score) = try offlineEngine("multiPartMixedStaves")
        defer { engine.teardown() }
        let url = Fixtures.temporaryFile("m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try await engine.exportAudioFile(to: url, score: score, format: format)
        let bytes = try Data(contentsOf: url)
        #expect(bytes.count > 1000)
        #expect(Array(bytes[4 ..< 8]) == Array("ftyp".utf8))
    }

    @Test func anAACRateTheEncoderCannotTakeIsUnsupported() {
        #expect(!WindowsPlaybackEngine.canExport(.m4a(CompressedOptions(sampleRate: 22050))))
        #expect(!WindowsPlaybackEngine.canExport(.m4a(CompressedOptions(bitRate: 64000))))
    }

    /// A `.defaultDevice` engine renders through a twin and is left as it was: its loop, its position, its mixer. An
    /// engine that rendered in place would end stopped at the top with no cursor.
    @Test func aLiveEngineExportsThroughATwinAndKeepsItsState() async throws {
        let engine = WindowsPlaybackEngine(soundfontResolver: Fixtures.silentResolver)
        defer { engine.teardown() }
        let score = try Fixtures.score("repeat52")
        try engine.prepare(score: score)
        engine.setLoop(
            from: .beat(measureIndex: 1, tickInMeasure: 0), to: .beat(measureIndex: 3, tickInMeasure: 0),
        )
        engine.seek(to: .beat(measureIndex: 2, tickInMeasure: 0))
        let strip = try #require(engine.mixerChannels.first { $0.id != .metronome })
        engine.setMuted(forChannel: strip.id, to: true)
        let before = (loop: engine.loopRange, cursor: engine.currentCursor, mixer: engine.mixerChannels)
        try #require(before.loop != nil)
        try #require(before.cursor != nil)
        let url = Fixtures.temporaryFile("wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try await engine.exportAudioFile(to: url, score: score, format: wav16)
        #expect(try wavFrames(url) > 0)
        #expect(engine.loopRange == before.loop)
        #expect(engine.currentCursor == before.cursor)
        #expect(engine.mixerChannels == before.mixer)
        #expect(engine.state == .stopped)
    }

    /// `.currentLoop` exports the live engine's loop, resolved on the engine that has it rather than on the twin.
    @Test func theCurrentLoopIsTheLiveEnginesLoop() async throws {
        let engine = WindowsPlaybackEngine(soundfontResolver: Fixtures.silentResolver)
        defer { engine.teardown() }
        let score = try Fixtures.score("repeat52")
        try engine.prepare(score: score)
        let full = Fixtures.temporaryFile("wav")
        let loop = Fixtures.temporaryFile("wav")
        defer { [full, loop].forEach { try? FileManager.default.removeItem(at: $0) } }
        engine.setLoop(
            from: .beat(measureIndex: 1, tickInMeasure: 0), to: .beat(measureIndex: 3, tickInMeasure: 0),
        )
        try await engine.exportAudioFile(to: full, score: score, format: wav16, range: .full)
        try await engine.exportAudioFile(to: loop, score: score, format: wav16, range: .currentLoop)
        #expect(try wavFrames(loop) < wavFrames(full) / 2)
    }
}

/// Progress values, appended from the export thread.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []

    func add(_ value: Double) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }

    var values: [Double] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
