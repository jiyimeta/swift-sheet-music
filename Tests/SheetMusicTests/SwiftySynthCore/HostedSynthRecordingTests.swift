#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    import SheetMusicAudioCore
    @testable import SheetMusicAudioSwiftySynthCore
    import Testing

    /// Android's half of the recordings: `HostedSynth.renderMix` runs the Apple backend's alignment and mix on a hosted
    /// score synth, with the metronome synth's transport following its speed. Against the silent placeholder font, so
    /// what the score buffers hold is the recordings alone, and PCM files whose samples say where they were read.
    @Suite("HostedSynth recordings and alignment")
    struct HostedSynthRecordingTests {
        static let sampleRate = 48000
        /// A recording sample that encodes its own frame: frame / 10, so a read position is a level.
        static let rampDivisor = 10

        /// A score synth with one recording of `frames` frames (the ramp, or `level` throughout) on the whole-file
        /// table, and an attached one-note sequence at 120 BPM, parked at its start.
        static func scoreSynth(
            frames: Int = 48000 * 6, level: Int16? = nil, warp: PlaybackTimeWarp? = nil,
        ) throws -> (synth: HostedSynth, sequence: HostedSequence, file: URL) {
            let synth = try #require(HostedSynth(sampleRate: sampleRate, voicing: .score))
            let file = try PCMCacheFixture.write(rate: sampleRate, frames: frames) { frame in
                level ?? Int16(frame / rampDivisor)
            }
            let recording = try MappedRecording(pcmFile: file)
            synth.setPlaybackAlignment(
                warp: warp, segments: [RecordingSegment(sourceStart: 0, sourceEnd: 100, outputStart: 0)],
            )
            synth.setRecordingTracks([RecordingTrackRender(id: "a", recording: recording)])
            let smf = try HostedSynthFixtures.smf(tempos: [(0, 120)], notes: [(0, 0, 60, 480 * 16)])
            let sequence = try #require(synth.attachSequence(smf: smf))
            return (synth, sequence, file)
        }

        /// A metronome synth with the click font and a click on every beat for 16 beats, attached and parked.
        static func metronomeSynth() throws -> (synth: HostedSynth, sequence: HostedSequence) {
            let synth = try #require(HostedSynth(sampleRate: sampleRate, voicing: .metronome))
            try synth.loadSoundFont(HostedSynthFixtures.clickFont())
            let notes = (0 ..< 16).map { (tick: $0 * 480, channel: 9, key: HostedSynthFixtures.strongKey, length: 60) }
            let smf = try HostedSynthFixtures.smf(tempos: [(0, 120)], notes: notes)
            return try (synth, #require(synth.attachSequence(smf: smf)))
        }

        /// `frames` frames of `synth.renderMix` with `metronome`, in 480-frame blocks as Android's writer pulls them.
        static func render(
            _ synth: HostedSynth, metronome: HostedSynth? = nil, audible: Bool = false, frames: Int,
        ) -> (score: [Float], clicks: [Float]) {
            let block = 480
            let left = StereoBuffer(frames: block)
            let right = StereoBuffer(frames: block)
            var score: [Float] = []
            var clicks: [Float] = []
            var done = 0
            while done < frames {
                let count = min(block, frames - done)
                synth.renderMix(
                    left: left.left, right: left.right, metronome: metronome, metronomeLeft: right.left,
                    metronomeRight: right.right, metronomeAudible: audible, frames: count,
                )
                score += Array(left.leftSamples.prefix(count))
                clicks += Array(right.leftSamples.prefix(count))
                done += count
            }
            return (score, clicks)
        }

        static func level(atSourceSeconds seconds: Double) -> Float {
            Float(Int(seconds * Double(sampleRate)) / rampDivisor) / 32768
        }

        @Test("a warp slows the score and the metronome alike, and the recording is read at the warped second")
        func warpSpeeds() throws {
            // Transport seconds 0 ..< 2 last 4 s: half speed.
            let warp = try PlaybackTimeWarp(spans: [.init(start: 0, end: 2, duration: 4)])
            let (synth, sequence, file) = try Self.scoreSynth(warp: warp)
            defer { try? FileManager.default.removeItem(at: file) }
            let (metronome, clicks) = try Self.metronomeSynth()
            sequence.play()
            clicks.play()

            let out = Self.render(synth, metronome: metronome, audible: true, frames: Self.sampleRate)

            // One second of output at half speed is half a second of transport: 480 ticks at 120 BPM.
            #expect(abs(synth.currentTransportSeconds - 0.5) < 0.005, "\(synth.currentTransportSeconds)")
            #expect(abs(sequence.currentTick - 480) <= 4, "score tick \(sequence.currentTick)")
            #expect(abs(clicks.currentTick - 480) <= 4, "the click follows the warp: tick \(clicks.currentTick)")
            #expect(abs(synth.outputSeconds(atTransport: synth.currentTransportSeconds) - 1) < 0.01)
            // The recording plays its first second of file across that second of output.
            let last = try #require(out.score.last)
            #expect(abs(last - Self.level(atSourceSeconds: 1)) < 0.002, "read at warped second 1: \(last)")
            let middle = out.score[Self.sampleRate / 2]
            #expect(abs(middle - Self.level(atSourceSeconds: 0.5)) < 0.002, "read at warped second 0.5: \(middle)")
        }

        @Test("without a warp the transport and the click run at the user's rate")
        func rateWithoutWarp() throws {
            let (synth, sequence, file) = try Self.scoreSynth()
            defer { try? FileManager.default.removeItem(at: file) }
            let (metronome, clicks) = try Self.metronomeSynth()
            sequence.setSpeed(2)
            sequence.play()
            clicks.play()
            _ = Self.render(synth, metronome: metronome, audible: true, frames: Self.sampleRate / 2)
            #expect(abs(sequence.currentTick - 960) <= 4, "score tick \(sequence.currentTick)")
            #expect(abs(clicks.currentTick - 960) <= 4, "click tick \(clicks.currentTick)")
        }

        @Test("a seek crossfades the recording from where it was to where the transport went")
        func crossfadeOnSeek() throws {
            let (synth, sequence, file) = try Self.scoreSynth()
            defer { try? FileManager.default.removeItem(at: file) }
            sequence.play()
            _ = Self.render(synth, frames: Self.sampleRate / 2)
            sequence.seek(toTick: 1920)
            let out = Self.render(synth, frames: 960).score

            // The first frame still plays the old stream's continuation; past the 5 ms fade only the new one.
            #expect(abs(out[0] - Self.level(atSourceSeconds: 0.5)) < 0.003, "continues from 0.5 s: \(out[0])")
            #expect(abs(out[400] - Self.level(atSourceSeconds: 2.008)) < 0.003, "reads 2 s on: \(out[400])")
            let steps = zip(out, out.dropFirst()).map { abs($1 - $0) }
            #expect((steps.max() ?? 0) < 0.002, "no step through the crossfade: \(steps.max() ?? 0)")
        }

        @Test("the recordings are silent while the score waits out a count-in, and fade in when it plays")
        func silenceDuringCountIn() throws {
            let (synth, sequence, file) = try Self.scoreSynth(level: 8000)
            defer { try? FileManager.default.removeItem(at: file) }
            let (metronome, clicks) = try Self.metronomeSynth()
            // The count: the click transport runs, the score's waits.
            clicks.play()
            let count = Self.render(synth, metronome: metronome, audible: true, frames: 4800)
            #expect(count.score.allSatisfy { $0 == 0 }, "nothing of the recording under the count")
            #expect((count.clicks.map(abs).max() ?? 0) > 0.01, "the click sounds")

            sequence.play()
            let body = Self.render(synth, metronome: metronome, audible: true, frames: 4800).score
            let full: Float = 8000 / 32768
            #expect(abs(body[0]) < 0.01, "fades in: \(body[0])")
            #expect(abs(body[480] - full) < 0.001, "at its level after the fade: \(body[480])")
        }

        @Test("a count-in under a warp runs at the speed of the measure it counts into")
        func countInUnderWarp() throws {
            let warp = try PlaybackTimeWarp(spans: [.init(start: 0, end: 2, duration: 4)])
            let (synth, _, file) = try Self.scoreSynth(warp: warp)
            defer { try? FileManager.default.removeItem(at: file) }
            let warped = synth.countIn(seconds: 2)
            #expect(warped.speed == 0.5)
            #expect(abs(warped.duration - 4) < 1e-9)

            let (plain, _, other) = try Self.scoreSynth()
            defer { try? FileManager.default.removeItem(at: other) }
            let unwarped = plain.countIn(seconds: 2)
            #expect(unwarped.speed == nil)
            #expect(abs(unwarped.duration - 2) < 1e-9)
        }

        @Test("without recordings or a warp, renderMix renders what render does, sample for sample")
        func matchesPlainRender() throws {
            func synthWithNotes() throws -> (HostedSynth, HostedSequence) {
                let synth = try #require(HostedSynth(sampleRate: Self.sampleRate, voicing: .metronome))
                try synth.loadSoundFont(HostedSynthFixtures.clickFont(seconds: 0.2))
                let notes = (0 ..< 8).map {
                    (tick: $0 * 240, channel: 9, key: HostedSynthFixtures.strongKey, length: 120)
                }
                let sequence = try #require(synth.attachSequence(smf: HostedSynthFixtures.smf(notes: notes)))
                sequence.play()
                return (synth, sequence)
            }
            let (mixed, _) = try synthWithNotes()
            let (plain, _) = try synthWithNotes()
            let mixedOut = Self.render(mixed, frames: Self.sampleRate).score
            let buffer = StereoBuffer(frames: 480)
            var plainOut: [Float] = []
            for _ in 0 ..< (Self.sampleRate / 480) {
                plain.render(left: buffer.left, right: buffer.right, frames: 480)
                plainOut += buffer.leftSamples
            }
            #expect(mixedOut == plainOut)
            #expect((mixedOut.map(abs).max() ?? 0) > 0.01, "the notes sound")
        }

        @Test("away from 100 % the recording is read through a stretcher the factory made")
        func stretchedAwayFromFullSpeed() throws {
            let made = StretcherLog()
            let (synth, sequence, file) = try Self.scoreSynth()
            defer { try? FileManager.default.removeItem(at: file) }
            synth.setRecordingStretcherFactory(RecordingStretcherFactory { _ in
                let stretcher = FakeStretcher(inputLatency: 64, outputLatency: 64)
                made.append(stretcher)
                return stretcher
            })
            // The track list again, so its group gets the factory's pairs at the new rate.
            let recording = try MappedRecording(pcmFile: file)
            sequence.setSpeed(0.7)
            synth.setRecordingTracks([RecordingTrackRender(id: "a", recording: recording)])
            sequence.play()
            _ = Self.render(synth, frames: 9600)
            #expect(made.count == 2, "one pair")
            #expect(made.processedInput > 0, "fed")
        }
    }

    /// The stretchers a test's factory made.
    private final class StretcherLog: @unchecked Sendable {
        private let lock = NSLock()
        private var stretchers: [FakeStretcher] = []

        func append(_ stretcher: FakeStretcher) {
            lock.withLock { stretchers.append(stretcher) }
        }

        var count: Int {
            lock.withLock { stretchers.count }
        }

        var processedInput: Int {
            lock.withLock { stretchers.reduce(0) { $0 + $1.processedInput } }
        }
    }
#endif
