#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    #if canImport(SwiftySynth)
        import AVFoundation
        import Foundation
        @testable import SheetMusicAudioApple
        @testable import SheetMusicAudioCore
        @testable import SheetMusicAudioSwiftySynth
        import SheetMusicCore
        import Testing

        extension AudioEngineSerial {
            /// `exportAudioFile` with a recording, an alignment and a count-in, rendered through a real
            /// `SwiftySynthBackend` and read back from the file. Nothing needs an asset: the font is a generated click
            /// SF2 and the recording a PCM cache file written in place.
            ///
            /// The score is four 4/4 measures of quarters at 120 BPM, 8 s on the transport, with its instrument muted;
            /// the warp makes the measures last 2.5, 2, 3 and 2.5 s, 10 s in all, so a count-in into the first lasts
            /// 2.5 s. The recording plays the reference from warped second 0 (`Fixtures`).
            @Suite("Export with recordings and a count-in")
            @MainActor
            final class RecordingExportTests {
                let font: URL
                let recordingFile: URL
                let score: Score

                init() throws {
                    font = try AudioEngineSerial.SwiftySynthRecordingRenderTests.writeClickSoundFont()
                    recordingFile = try Self.writeRecording()
                    score = Self.makeScore()
                }

                deinit {
                    try? FileManager.default.removeItem(at: font)
                    try? FileManager.default.removeItem(at: recordingFile)
                }

                private func engineWithRecording(_ file: URL? = nil) throws -> PlaybackEngine {
                    let engine = try Self.makeEngine(font: font, score: score)
                    try engine.setRecordingTracks([RecordingTrack(id: "rec", pcmFile: file ?? recordingFile)])
                    try engine.setAlignment(warp: Self.warp(), segments: Self.segments)
                    return engine
                }

                /// Each impulse of the recording lands `bodyStart` + its reference second into the file, within 1 ms.
                private func expectImpulsesOnTheirBeats(in samples: [Float], bodyStart: Int) {
                    for seconds in Self.impulseSeconds {
                        let offset = Self.impulseOffset(in: samples, expected: bodyStart + Self.frame(seconds))
                        #expect(
                            offset.map { abs($0) <= Self.millisecond } == true,
                            "impulse at \(seconds) s: \(offset.map(String.init) ?? "missing") frames off",
                        )
                    }
                }

                @Test("without a count-in the file lasts the warped body, the recording on its beats")
                func warpedExportLastsTheWarpedBody() async throws {
                    let samples = try await Self.export(engineWithRecording(), score, countIn: false)

                    let body = Self.frame(10)
                    #expect(samples.count >= body, "the body is never cut short: \(samples.count) frames")
                    #expect(samples.count - body <= Self.buffer, "\(samples.count) frames")
                    let first = try #require(Self.firstAudible(in: samples))
                    #expect(first <= Self.millisecond, "first audible frame \(first)")
                    expectImpulsesOnTheirBeats(in: samples, bodyStart: 0)
                }

                @Test("with a count-in the file opens with one warped measure, and the recording starts on the body")
                func countInPrecedesTheWarpedBody() async throws {
                    let samples = try await Self.export(engineWithRecording(), score, countIn: true)

                    // One 4/4 measure, counting into the first, at its speed: 2 s ÷ 0.8.
                    let countIn = Self.frame(2.5)
                    let end = countIn + Self.frame(10)
                    #expect(samples.count >= end, "the body is never cut short: \(samples.count) frames")
                    #expect(samples.count - end <= Self.buffer, "\(samples.count) frames")
                    // The click is at volume 0 here, so what is heard first is the recording.
                    let first = try #require(Self.firstAudible(in: samples))
                    #expect(abs(first - countIn) <= Self.millisecond, "first audible frame \(first), body \(countIn)")
                    expectImpulsesOnTheirBeats(in: samples, bodyStart: countIn)
                }

                @Test("a muted recording is silent in the file")
                func mutedRecordingIsSilent() async throws {
                    let engine = try engineWithRecording()
                    let firstMeasure = AudioExportRange.region(
                        from: .beat(measureIndex: 0, tickInMeasure: 0), to: .beat(measureIndex: 1, tickInMeasure: 0),
                    )
                    let heard = try await Self.export(engine, score, range: firstMeasure, countIn: false)
                    #expect(Self.peak(heard[...]) > 0.4, "unmuted, the recording's opening 0.5 is in the file")

                    engine.setRecordingMix(id: "rec", volume: 1, isMuted: true, isSoloed: false)
                    let muted = try await Self.export(engine, score, range: firstMeasure, countIn: false)

                    #expect(muted.count == heard.count)
                    #expect(Self.peak(muted[...]) < 1e-6)
                }

                @Test("the count-in sounds at the warped speed with the metronome strip muted, which then stays silent")
                func countInSoundsWithTheStripMuted() async throws {
                    let engine = try Self.makeEngine(font: font, score: score, metronomeVolume: 1)
                    try engine.setAlignment(warp: Self.warp(), segments: [])
                    let samples = try await Self.export(engine, score, countIn: true)

                    // Four clicks a warped beat apart (0.5 s ÷ 0.8); a note starts on the click synth's next 64-frame
                    // block, so an onset is up to a block late.
                    for beat in 0 ..< 4 {
                        let expected = Self.frame(Double(beat) * 0.625)
                        let onset = Self.firstAudible(in: samples, from: expected - 64, threshold: 0.01)
                        #expect(
                            onset.map { (0 ... 64).contains($0 - expected) } == true,
                            "click \(beat): onset \(onset.map(String.init) ?? "missing"), expected \(expected)",
                        )
                    }
                    let countIn = Self.frame(2.5)
                    #expect(Self.peak(samples[countIn...]) < 1e-6, "the strip is muted: no click in the body")
                }

                @Test("a loop range exports its measures' warped length, counted in at their speed")
                func loopRangeExportsWarped() async throws {
                    let engine = try engineWithRecording()
                    engine.setLoop(
                        from: .beat(measureIndex: 1, tickInMeasure: 0), to: .beat(measureIndex: 3, tickInMeasure: 0),
                    )
                    let samples = try await Self.export(engine, score, range: .currentLoop, countIn: true)

                    // Measures 2 and 3 last 2 + 3 s; the count into the second, whose stretch is 1, lasts 2 s.
                    let countIn = Self.frame(2)
                    let end = countIn + Self.frame(5)
                    #expect(samples.count >= end, "\(samples.count) frames")
                    #expect(samples.count - end <= Self.buffer, "\(samples.count) frames")
                    // The third measure's downbeat, warped second 4.5, is 2 s into the loop.
                    let offset = Self.impulseOffset(in: samples, expected: countIn + Self.frame(2))
                    #expect(offset.map { abs($0) <= Self.millisecond } == true, "\(offset.map(String.init) ?? "none")")
                }

                /// A seek parks the transport short of the onset, and each span boundary can leave it a little late, so
                /// a warped body can end after its warped length; the file must still hold all of it.
                @Test("a warped range is never cut short: the recording plays to the range's end, and little past it")
                func warpedRangeEndsInTheFile() async throws {
                    // The loop, measures 2 and 3, ends at warped second 7.5, where the recording drops to silence.
                    let step = try Self.writeStepRecording(at: 7.5)
                    defer { try? FileManager.default.removeItem(at: step) }
                    let engine = try engineWithRecording(step)
                    engine.setLoop(
                        from: .beat(measureIndex: 1, tickInMeasure: 0), to: .beat(measureIndex: 3, tickInMeasure: 0),
                    )
                    let samples = try await Self.export(engine, score, range: .currentLoop, countIn: false)

                    let last = try #require(Self.lastLoud(in: samples))
                    #expect(last < samples.count - 1, "the range's end is in the file: \(last) of \(samples.count)")
                    #expect(samples.count - 1 - last <= 2 * Self.millisecond, "\(last) of \(samples.count)")
                    #expect(abs(samples[samples.count / 2] - 0.5) < 1e-3, "the range plays the recording")
                }
            }
        }
    #endif

    extension AudioEngineSerial {
        /// What an export hands the backend's offline instance, against `RecordingBackend`: the recordings and the
        /// alignment the live engine plays, the solo bus across both kinds of strip, the count-in, and — with none of
        /// them — exactly what it handed before recordings existed.
        @Suite("Export plumbing for recordings and the count-in")
        @MainActor
        final class RecordingExportPlumbingTests {
            private struct NullResolver: SoundfontResolver {
                func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
                    nil
                }

                var defaultGMSoundfontURL: URL? {
                    nil
                }
            }

            private static let piano = MixerChannel.Kind.instrument(partIndex: 0, ordinal: 0)

            private let live = RecordingBackend()
            private let engine: PlaybackEngine
            private let score: Score
            private let file: URL

            init() throws {
                score = Self.makeScore()
                file = try PCMCacheFixture.write(rate: 44100, frames: 4410) { _ in 1000 }
                engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: live)
                try engine.prepare(score: score)
                engine.setVolume(forChannel: Self.piano, to: 1)
            }

            deinit {
                try? FileManager.default.removeItem(at: file)
            }

            /// Two 4/4 measures of quarters at 120 BPM: 4 s.
            private static func makeScore() -> Score {
                let quarter = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
                let first = Voice(elements: [.timeSignature(TimeSignature(numerator: 4, denominator: 4))]
                    + Array(repeating: VoiceElement.chord(quarter), count: 4))
                let second = Voice(elements: Array(repeating: VoiceElement.chord(quarter), count: 4))
                let part = Part(
                    id: "p", instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
                    staves: [Staff(measures: [Measure(voices: [first]), Measure(voices: [second])])],
                )
                return Score(division: 480, parts: [part])
            }

            /// Exports to a 44.1 kHz WAV and returns the offline instance and the file's length in frames.
            private func export(countIn: Bool = false) async throws -> (offline: RecordingBackend, frames: Int64) {
                let url = AudioExportProbe.temporaryWAV()
                defer { try? FileManager.default.removeItem(at: url) }
                try await engine.exportAudioFile(to: url, score: score, format: .wav(), includesCountIn: countIn)
                return try (#require(live.offlineInstance), AVAudioFile(forReading: url).length)
            }

            private func pianoCC7(on backend: RecordingBackend) -> [UInt8] {
                guard let channel = engine.midiChannel(forChannel: Self.piano) else { return [] }
                return backend.volumeSends.filter { $0.channel == channel }.map(\.cc7)
            }

            @Test("without recordings, an alignment or a count-in the export hands over what it always did")
            func plainExportIsUnchanged() async throws {
                let (offline, frames) = try await export()

                #expect(offline.recordingTrackCalls.isEmpty)
                #expect(offline.alignmentCalls.isEmpty)
                #expect(offline.countInSeconds == nil)
                #expect(offline.didPlay)
                #expect(offline.seekCalls == [0])
                #expect(offline.metronomeOffsetSeconds == 0)
                #expect(frames == 4 * 44100)
            }

            @Test("the offline instance gets the live recordings, the same mapped files, and the alignment")
            func recordingsAndAlignmentReachTheOfflineInstance() async throws {
                try engine.setRecordingTracks([RecordingTrack(id: "A", pcmFile: file, offsetSeconds: 0.5, volume: 0.6)])
                let warp = try PlaybackTimeWarp(spans: [.init(start: 0, end: 2, duration: 2.5)])
                let segments = [RecordingSegment(sourceStart: 0, sourceEnd: 4, outputStart: 0)]
                engine.setAlignment(warp: warp, segments: segments)
                let sent = try #require(live.recordingTrackCalls.last)

                let (offline, frames) = try await export()

                let tracks = try #require(offline.recordingTrackCalls.last)
                #expect(tracks.map(\.id) == ["A"])
                #expect(tracks.map(\.gain) == [0.6])
                #expect(tracks.map(\.offsetSeconds) == [0.5])
                #expect(zip(tracks, sent).allSatisfy { $0.recording === $1.recording }, "the same mapped file")
                #expect(offline.alignmentCalls.last?.warp == warp)
                #expect(offline.alignmentCalls.last?.segments == segments)
                // The first measure lasts 2.5 s, the second 2: 4.5 s, and an allowance for the one boundary inside.
                #expect(frames >= Int64(4.5 * 44100))
                #expect(frames - Int64(4.5 * 44100) <= Int64(AudioFileExporter.bufferFrames))
            }

            @Test("a soloed recording silences the instruments in the file, and a soloed instrument the recordings")
            func soloSpansBothKindsInTheExport() async throws {
                try engine.setRecordingTracks([RecordingTrack(id: "A", pcmFile: file)])

                engine.setRecordingMix(id: "A", volume: 1, isMuted: false, isSoloed: true)
                let soloedRecording = try await export().offline
                #expect(!pianoCC7(on: soloedRecording).isEmpty)
                #expect(pianoCC7(on: soloedRecording).allSatisfy { $0 == 0 })
                #expect(soloedRecording.recordingTrackCalls.last?.map(\.gain) == [1])

                engine.setRecordingMix(id: "A", volume: 1, isMuted: false, isSoloed: false)
                engine.setSoloed(forChannel: Self.piano, to: true)
                let soloedPiano = try await export().offline
                #expect(pianoCC7(on: soloedPiano).last == 127)
                #expect(soloedPiano.recordingTrackCalls.last?.map(\.gain) == [0])
            }

            @Test("a count-in reaches the offline instance as the live one does, and the file grows by it")
            func countInReachesTheOfflineInstance() async throws {
                let (offline, frames) = try await export(countIn: true)

                // One 4/4 measure at 120 BPM, a whole pre-roll ahead of the body on the metronome's clock.
                #expect(offline.countInSeconds.map { abs($0 - 2) < 1e-9 } == true)
                #expect(abs(offline.metronomeOffsetSeconds - 2) < 1e-9)
                #expect(offline.seekCalls == [0])
                #expect(frames == 6 * 44100)
            }
        }
    }
#endif
