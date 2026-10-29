#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    #if canImport(SwiftySynth)
        import Foundation
        @testable import SheetMusicAudioApple
        @testable import SheetMusicAudioCore
        @testable import SheetMusicAudioSwiftySynth
        import SheetMusicCore
        import SheetMusicMIDI
        import Testing

        extension AudioEngineSerial {
            /// Where a seek parks the transport, and what that does to an export, after a backward jump and before a
            /// slow measure — through a real `SwiftySynthBackend`, with the fixtures of `RecordingExportTests`.
            ///
            /// A seek parks half a tick before the onset so the onset's note-on is dispatched. Taken on the notated
            /// clock before projecting, that half tick puts the downbeat after a repeat at the end of the repeated
            /// pass; and at a slow tempo it puts a count-in's speed lookup in the measure before the body.
            @Suite("Seek and export over a repeat and a slow measure")
            @MainActor
            final class RecordingExportRepeatTests {
                private typealias Fixtures = AudioEngineSerial.RecordingExportTests

                let font: URL

                init() throws {
                    font = try AudioEngineSerial.SwiftySynthRecordingRenderTests.writeClickSoundFont()
                }

                deinit {
                    try? FileManager.default.removeItem(at: font)
                }

                /// `measures` 4/4 measures of quarters at `beatsPerSecond`; with `repeatFirst`, `|: A :| B`.
                private static func score(measures: Int, beatsPerSecond: Double, repeatFirst: Bool = false) -> Score {
                    let quarter = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
                    let staff = (0 ..< measures).map { index -> Measure in
                        var elements: [VoiceElement] = []
                        if index == 0 { elements.append(.timeSignature(TimeSignature(numerator: 4, denominator: 4))) }
                        elements += Array(repeating: VoiceElement.chord(quarter), count: 4)
                        let repeated = repeatFirst && index == 0
                        return Measure(
                            voices: [Voice(elements: elements)],
                            startRepeat: repeated, endRepeatCount: repeated ? 2 : nil,
                        )
                    }
                    let part = Part(
                        id: "p0", instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
                        staves: [Staff(measures: staff)],
                    )
                    let tempo = PositionedSystemElement(
                        position: .start, element: .tempo(Tempo(beatsPerSecond: beatsPerSecond)),
                    )
                    let first = SystemMeasure(elements: [tempo])
                    let rest = Array(repeating: SystemMeasure(), count: measures - 1)
                    return Score(
                        division: 480, parts: [part], systemMeasures: IdentifiedArray([first] + rest), metaTags: [:],
                    )
                }

                /// A 10 s recording at `level(warped second)`.
                private static func writeRecording(_ level: (Double) -> Double) throws -> URL {
                    try PCMCacheFixture.write(rate: 44100, frames: Fixtures.frame(10)) { frame in
                        Int16((level(Double(frame) / Fixtures.sampleRate) * 32768).rounded())
                    }
                }

                @Test("a seek to the downbeat after a repeat parks half a tick before it, not at the repeat's end")
                func seekPastARepeatParksBeforeItsTarget() async throws {
                    let score = Self.score(measures: 2, beatsPerSecond: 2, repeatFirst: true)
                    let derivation = PreparedPlayback.derive(score: score)
                    let backend = SwiftySynthBackend(sampleRate: Fixtures.sampleRate)
                    backend.prepare(soundfontURL: font, metronomeSoundfontURL: font, drumChannels: [])
                    for _ in 0 ..< 250 where !backend.isReady {
                        try await Task.sleep(for: .milliseconds(20))
                    }
                    try #require(backend.isReady, "SwiftySynthBackend never became ready")
                    try backend.loadSequence(MidiRenderer.render(score: score), timeline: derivation.timeline)
                    backend.setUnrolledTimeMap(derivation.unrolledTimeMap)
                    let halfTick = 0.5 * 0.5 / 480

                    // |: A :| B at 120 BPM: B's downbeat is notated 2 s and plays at 4 s, after A's repeat.
                    backend.seek(toTick: 1920)
                    let afterRepeat = backend.currentPositionSeconds
                    #expect(abs(afterRepeat - (4 - halfTick)) < 1e-9, "\(afterRepeat)")
                    // Inside a measure-play nothing moves: B's second beat, A's second beat, the top.
                    backend.seek(toTick: 2400)
                    #expect(abs(backend.currentPositionSeconds - (4.5 - halfTick)) < 1e-9)
                    backend.seek(toTick: 480)
                    #expect(abs(backend.currentPositionSeconds - (0.5 - halfTick)) < 1e-9)
                    backend.seek(toTick: 0)
                    #expect(backend.currentPositionSeconds == 0)
                }

                /// `|: A :| B` with a warp over each measure-play: A lasts 2.5 s, its repeat 2 s, B 3 s. The recording
                /// is 0.2 under A, 0.4 under its repeat, 0.6 under B, and silent after.
                @Test("a warped export of the measure after a repeat plays that measure, for its warped length")
                func warpedExportAfterARepeat() async throws {
                    let score = Self.score(measures: 2, beatsPerSecond: 2, repeatFirst: true)
                    let file = try Self.writeRecording { $0 < 2.5 ? 0.2 : $0 < 4.5 ? 0.4 : $0 < 7.5 ? 0.6 : 0 }
                    defer { try? FileManager.default.removeItem(at: file) }
                    let engine = try Fixtures.makeEngine(font: font, score: score)
                    try engine.setRecordingTracks([RecordingTrack(id: "rec", pcmFile: file)])
                    try engine.setAlignment(
                        warp: PlaybackTimeWarp(spans: [
                            .init(start: 0, end: 2, duration: 2.5), .init(start: 2, end: 4, duration: 2),
                            .init(start: 4, end: 6, duration: 3),
                        ]),
                        segments: [RecordingSegment(sourceStart: 0, sourceEnd: 10, outputStart: 0)],
                    )
                    let b = AudioExportRange.region(
                        from: .beat(measureIndex: 1, tickInMeasure: 0), to: .beat(measureIndex: 1, tickInMeasure: 1920),
                    )
                    let samples = try await Fixtures.export(engine, score, range: b, countIn: false)

                    let body = Fixtures.frame(3)
                    #expect(samples.count >= body, "\(samples.count) frames")
                    #expect(samples.count - body <= 2 * Fixtures.millisecond, "\(samples.count) frames")
                    // Past the 5 ms fade-in and in the middle: B's level, not the repeat's.
                    #expect(abs(samples[Fixtures.frame(0.01)] - 0.6) < 0.01, "\(samples[Fixtures.frame(0.01)])")
                    #expect(abs(samples[body / 2] - 0.6) < 0.01, "\(samples[body / 2])")
                    // B's end is in the file.
                    let last = try #require(Fixtures.lastLoud(in: samples))
                    #expect(last < samples.count - 1, "\(last) of \(samples.count)")
                }

                /// Two 4/4 measures at 60 BPM, so half a tick (1.04 ms) is more than the count-in's 1 ms lookup: the
                /// first lasts 5 s (stretch 0.8), the second 4 s (stretch 1). The recording is 0.5 under the second.
                @Test("a count-in into a slow measure runs at that measure's speed, and the file holds all of it")
                func slowCountInRunsAtTheBodysSpeed() async throws {
                    let score = Self.score(measures: 2, beatsPerSecond: 1)
                    let file = try Self.writeRecording { $0 >= 5 && $0 < 9 ? 0.5 : 0 }
                    defer { try? FileManager.default.removeItem(at: file) }
                    let engine = try Fixtures.makeEngine(font: font, score: score)
                    try engine.setRecordingTracks([RecordingTrack(id: "rec", pcmFile: file)])
                    try engine.setAlignment(
                        warp: PlaybackTimeWarp(spans: [
                            .init(start: 0, end: 4, duration: 5), .init(start: 4, end: 8, duration: 4),
                        ]),
                        segments: [RecordingSegment(sourceStart: 0, sourceEnd: 10, outputStart: 0)],
                    )
                    let second = AudioExportRange.region(
                        from: .beat(measureIndex: 1, tickInMeasure: 0), to: .beat(measureIndex: 1, tickInMeasure: 1920),
                    )
                    let samples = try await Fixtures.export(engine, score, range: second, countIn: true)

                    // A 4 s count at stretch 1, then the 4 s measure.
                    let countIn = Fixtures.frame(4)
                    let end = countIn + Fixtures.frame(4)
                    #expect(samples.count >= end, "\(samples.count) frames")
                    #expect(samples.count - end <= 2 * Fixtures.millisecond, "\(samples.count) frames")
                    // The recording starts with the body: after the half tick the seek parks before it (≈ 1.3 ms here,
                    // at stretch 0.8), within 3 ms.
                    let first = try #require(Fixtures.firstAudible(in: samples))
                    #expect(
                        (0 ... 3 * Fixtures.millisecond).contains(first - countIn), "first \(first), body \(countIn)",
                    )
                    let last = try #require(Fixtures.lastLoud(in: samples))
                    #expect(last < samples.count - 1, "the body's end is in the file: \(last) of \(samples.count)")
                }
            }
        }
    #endif
#endif
