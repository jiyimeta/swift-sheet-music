#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    import SheetMusicCore
    import Testing

    extension AudioEngineSerial {
        /// `PlaybackEngine`'s recording tracks and alignment, against `RecordingBackend`, which records what the engine
        /// hands a backend: the mix each track resolves to (solo spans instruments and recordings), the transposition,
        /// a failed file, an alignment set while playing, and the clock the seek bar reads. Nothing renders; the sound
        /// of a gain change is `SwiftySynthRecordingGainRampTests`'.
        ///
        /// The score is two parts of three 4/4 measures of quarters at 120 BPM, so a measure lasts 2 s; the warp makes
        /// the first one last 2.5 s.
        @Suite("PlaybackEngine recording tracks and alignment")
        @MainActor
        final class PlaybackEngineRecordingTests {
            private struct NullResolver: SoundfontResolver {
                func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
                    nil
                }

                var defaultGMSoundfontURL: URL? {
                    nil
                }
            }

            private static let piano = MixerChannel.Kind.instrument(partIndex: 0, ordinal: 0)
            private static let guitar = MixerChannel.Kind.instrument(partIndex: 1, ordinal: 0)

            private let backend: RecordingBackend
            private let score: Score
            private let engine: PlaybackEngine
            private let fileA: URL
            private let fileB: URL

            init() throws {
                fileA = try PCMCacheFixture.write(rate: 44100, frames: 4410) { _ in 1000 }
                fileB = try PCMCacheFixture.write(rate: 44100, frames: 4410) { _ in 2000 }
                backend = RecordingBackend()
                score = Self.makeScore()
                engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                try engine.prepare(score: score)
                // Full volume, so a strip that sounds sends CC 7 = 127 (the score's default is 100).
                engine.setVolume(forChannel: Self.piano, to: 1)
                engine.setVolume(forChannel: Self.guitar, to: 1)
            }

            deinit {
                try? FileManager.default.removeItem(at: fileA)
                try? FileManager.default.removeItem(at: fileB)
            }

            private static func makeScore() -> Score {
                let quarter = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
                func measure(first: Bool) -> Measure {
                    var elements: [VoiceElement] = []
                    if first {
                        elements.append(.timeSignature(TimeSignature(numerator: 4, denominator: 4)))
                    }
                    elements += Array(repeating: VoiceElement.chord(quarter), count: 4)
                    return Measure(voices: [Voice(elements: elements)])
                }
                func part(_ id: String, program: Int) -> Part {
                    Part(
                        id: id,
                        instrument: Instrument(id: "i-\(id)", channels: [InstrumentChannel(program: program)]),
                        staves: [Staff(measures: [measure(first: true), measure(first: false), measure(first: false)])],
                    )
                }
                let tempo = SystemMeasure(elements: [
                    PositionedSystemElement(position: .start, element: .tempo(Tempo(beatsPerSecond: 2.0))),
                ])
                return Score(
                    division: 480, parts: [part("p0", program: 0), part("p1", program: 40)],
                    systemMeasures: IdentifiedArray([tempo, SystemMeasure(), SystemMeasure()]), metaTags: [:],
                )
            }

            /// Transport seconds 0–2 (the first measure) last 2.5 s.
            private static func warp() throws -> PlaybackTimeWarp {
                try PlaybackTimeWarp(spans: [.init(start: 0, end: 2, duration: 2.5)])
            }

            private static let wholeRecording = [RecordingSegment(sourceStart: 0, sourceEnd: 10, outputStart: 0)]

            private func track(
                _ id: String, _ file: URL, offset: TimeInterval = 0, transpose: Int = 0, volume: Float = 1,
                muted: Bool = false,
            ) -> RecordingTrack {
                RecordingTrack(
                    id: id, pcmFile: file, offsetSeconds: offset, transposeSemitones: transpose, volume: volume,
                    isMuted: muted,
                )
            }

            /// The CC 7 the engine last sent an instrument strip's MIDI channel.
            private func lastCC7(_ id: MixerChannel.Kind) -> UInt8? {
                guard let channel = engine.midiChannel(forChannel: id) else { return nil }
                return backend.volumeSends.last { $0.channel == channel }?.cc7
            }

            private var lastTracks: [RecordingTrackRender] {
                backend.recordingTrackCalls.last ?? []
            }

            private var gains: [String: Float] {
                Dictionary(uniqueKeysWithValues: lastTracks.map { ($0.id, $0.gain) })
            }

            // MARK: Mix

            @Test("the resolved gain and the offset of each track reach the backend")
            func gainAndOffsetReachTheBackend() throws {
                try engine.setRecordingTracks([
                    track("A", fileA, volume: 0.5), track("B", fileB, offset: 1.5, volume: 0.8),
                ])

                #expect(lastTracks.map(\.id) == ["A", "B"])
                #expect(lastTracks.map(\.gain) == [0.5, 0.8])
                #expect(lastTracks.map(\.offsetSeconds) == [0, 1.5])
                #expect(lastTracks.map(\.transposeSemitones) == [0, 0])
            }

            @Test("soloing a recording silences every unsoloed instrument and recording, but not the click")
            func recordingSoloSilencesTheInstruments() throws {
                engine.setMuted(forChannel: .metronome, to: false)
                try engine.setRecordingTracks([track("A", fileA), track("B", fileB)])
                #expect(lastCC7(Self.piano) == 127)

                engine.setRecordingMix(id: "A", volume: 1, isMuted: false, isSoloed: true)

                #expect(lastCC7(Self.piano) == 0)
                #expect(lastCC7(Self.guitar) == 0)
                #expect(gains == ["A": 1, "B": 0])
                #expect(backend.metronomeMuted == false, "the click is off the solo bus")
            }

            @Test("soloing an instrument silences every recording that is not soloed")
            func instrumentSoloSilencesTheRecordings() throws {
                try engine.setRecordingTracks([track("A", fileA), track("B", fileB)])

                engine.setSoloed(forChannel: Self.piano, to: true)

                #expect(lastCC7(Self.piano) == 127)
                #expect(lastCC7(Self.guitar) == 0)
                #expect(gains == ["A": 0, "B": 0])
            }

            @Test("un-soloing everything gives each strip its own mute back")
            func unsoloRestoresEachMute() throws {
                try engine.setRecordingTracks([track("A", fileA), track("B", fileB, muted: true)])
                engine.setMuted(forChannel: Self.guitar, to: true)

                engine.setRecordingMix(id: "A", volume: 1, isMuted: false, isSoloed: true)
                #expect(lastCC7(Self.piano) == 0)
                engine.setRecordingMix(id: "A", volume: 1, isMuted: false, isSoloed: false)
                #expect(lastCC7(Self.piano) == 127)
                #expect(lastCC7(Self.guitar) == 0, "muted before the solo")
                #expect(gains == ["A": 1, "B": 0])

                engine.setSoloed(forChannel: Self.piano, to: true)
                #expect(gains == ["A": 0, "B": 0])
                engine.setSoloed(forChannel: Self.piano, to: false)
                #expect(gains == ["A": 1, "B": 0], "B was muted before the solo")
            }

            @Test("a mix change hands over the same tracks, only the gain changed")
            func mixChangeKeepsTheTracks() throws {
                try engine.setRecordingTracks([track("A", fileA), track("B", fileB)])
                let before = lastTracks
                let calls = backend.recordingTrackCalls.count

                engine.setRecordingMix(id: "A", volume: 0.3, isMuted: false, isSoloed: false)

                #expect(backend.recordingTrackCalls.count == calls + 1)
                #expect(lastTracks.map(\.id) == ["A", "B"])
                #expect(zip(lastTracks, before).allSatisfy { $0.recording === $1.recording }, "same mapped files")
                #expect(gains == ["A": 0.3, "B": 1])
            }

            @Test("a mixer change that leaves every recording's gain where it was hands nothing over")
            func unrelatedMixerChangeSendsNoTracks() throws {
                try engine.setRecordingTracks([track("A", fileA)])
                let calls = backend.recordingTrackCalls.count

                engine.setVolume(forChannel: Self.piano, to: 0.5)
                engine.setMuted(forChannel: Self.guitar, to: true)

                #expect(backend.recordingTrackCalls.count == calls)
            }

            @Test("each track plays at the reader's transposition plus its own")
            func transpositionReachesTheTracks() throws {
                engine.setTranspose(semitones: 1)
                try engine.setRecordingTracks([track("A", fileA), track("B", fileB, transpose: 2)])
                #expect(lastTracks.map(\.transposeSemitones) == [1, 3])
                let before = lastTracks

                engine.setTranspose(semitones: -2)

                #expect(lastTracks.map(\.transposeSemitones) == [-2, 0])
                #expect(lastTracks.map(\.id) == ["A", "B"])
                #expect(zip(lastTracks, before).allSatisfy { $0.recording === $1.recording }, "same mapped files")
            }

            @Test("a track list with a file that cannot be mapped throws and leaves the playing tracks alone")
            func unmappableFileThrowsWithoutTouchingTheTracks() throws {
                try engine.setRecordingTracks([track("A", fileA)])
                let calls = backend.recordingTrackCalls.count
                let missing = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID()).pcm")

                #expect(throws: MappedRecording.Failure.self) {
                    try self.engine.setRecordingTracks([self.track("A", self.fileA), self.track("C", missing)])
                }

                #expect(backend.recordingTrackCalls.count == calls, "nothing reached the backend")
                engine.setRecordingMix(id: "A", volume: 0.4, isMuted: false, isSoloed: false)
                #expect(lastTracks.map(\.id) == ["A"], "the earlier tracks are still the engine's")
                #expect(gains == ["A": 0.4])
            }

            // MARK: Alignment

            @Test("an alignment set while playing reaches the backend without moving the transport")
            func alignmentWhilePlayingLeavesTheTransport() throws {
                engine.play(in: score)
                #expect(engine.state == .playing)
                let plays = backend.playCallCount
                let pauses = backend.pauseCallCount
                let stops = backend.stopCallCount
                let seeks = backend.seekCalls.count
                let warp = try Self.warp()

                engine.setAlignment(warp: warp, segments: Self.wholeRecording)

                #expect(backend.alignmentCalls.count == 1)
                #expect(backend.alignmentCalls.last?.warp == warp)
                #expect(backend.alignmentCalls.last?.segments == Self.wholeRecording)
                #expect(backend.playCallCount == plays)
                #expect(backend.pauseCallCount == pauses)
                #expect(backend.stopCallCount == stops)
                #expect(backend.seekCalls.count == seeks)
                #expect(engine.state == .playing)
                #expect(engine.hasAlignment)
            }

            @Test("with an alignment the elapsed and total time are the warped seconds the seek bar shows")
            func timeIsReportedOnTheWarpedClock() throws {
                try engine.setAlignment(warp: Self.warp(), segments: Self.wholeRecording)

                // 1.2 s into the first measure, which lasts 2.5 s: 1.5 warped seconds. Snapped, the onset at 1.0 s.
                backend.currentPositionSeconds = 1.2
                #expect(abs(engine.currentTimeSecondsContinuous - 1.5) < 1e-9)
                #expect(abs(engine.currentTimeSeconds - 1.25) < 1e-9)
                // Past the span the warped clock runs 0.5 s ahead of the transport's.
                backend.currentPositionSeconds = 3.0
                #expect(abs(engine.currentTimeSecondsContinuous - 3.5) < 1e-9)
                #expect(abs(engine.totalTimeSeconds - 6.5) < 1e-9)
            }

            @Test("with an alignment seek and skip take warped seconds")
            func seekAndSkipTakeWarpedSeconds() throws {
                engine.play(in: score)
                try engine.setAlignment(warp: Self.warp(), segments: Self.wholeRecording)

                // Warped 3.0 s is transport 2.5 s: the third quarter of the second measure, tick 2400.
                engine.seek(toTimeSeconds: 3.0)
                #expect(backend.seekCalls.last == 2400)
                // From warped 3.0 s back to 2.0 s, transport 1.6 s: the quarter that starts at 1.5 s, tick 1440.
                engine.skip(by: -1.0)
                #expect(backend.seekCalls.last == 1440)
            }

            @Test("with an alignment the continuous time folds into the loop on the transport's clock")
            func loopFoldsBeforeTheWarp() throws {
                try engine.setAlignment(warp: Self.warp(), segments: Self.wholeRecording)
                engine.setLoop(
                    from: .beat(measureIndex: 1, tickInMeasure: 0), to: .beat(measureIndex: 2, tickInMeasure: 0),
                )

                // Polled past the loop's end (transport 4 s) before the wrap: transport 2.5 s, warped 3.0 s.
                backend.currentPositionSeconds = 4.5
                #expect(abs(engine.currentTimeSecondsContinuous - 3.0) < 1e-9)
            }

            @Test("without an alignment the clock is the notated one, as before, also once one is cleared")
            func withoutAlignmentTheClockIsUnchanged() throws {
                func expectNotatedClock() {
                    backend.currentPositionSeconds = 1.2
                    #expect(abs(engine.currentTimeSeconds - 1.0) < 1e-9)
                    #expect(abs(engine.currentTimeSecondsContinuous - 1.2) < 1e-9)
                    #expect(abs(engine.totalTimeSeconds - 6.0) < 1e-9)
                    #expect(!engine.hasAlignment)
                    engine.seek(toTimeSeconds: 3.0)
                    #expect(backend.seekCalls.last == 2880)
                }
                engine.play(in: score)
                expectNotatedClock()

                try engine.setAlignment(warp: Self.warp(), segments: Self.wholeRecording)
                engine.setAlignment(warp: nil, segments: [])
                expectNotatedClock()
            }

            @Test("a backend that cannot play recordings keeps the notated clock under an alignment")
            func backendWithoutRecordingsKeepsTheNotatedClock() throws {
                backend.canPlayRecordings = false
                try engine.setAlignment(warp: Self.warp(), segments: Self.wholeRecording)

                backend.currentPositionSeconds = 1.2
                #expect(!engine.hasAlignment)
                #expect(abs(engine.currentTimeSecondsContinuous - 1.2) < 1e-9)
            }
        }
    }
#endif
