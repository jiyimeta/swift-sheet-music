#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    #if canImport(SwiftySynth)
        import Foundation
        @testable import SheetMusicAudioApple
        @testable import SheetMusicAudioCore
        @testable import SheetMusicAudioSwiftySynth
        import SheetMusicCore
        import Testing

        extension AudioEngineSerial {
            /// Which track-list changes restart a stretched group, end to end: what `PlaybackEngine` hands its backend
            /// (recorded by `RecordingBackend`) is handed on to a `SwiftySynthBackend` reading through `FakeStretcher`
            /// pairs at 70 %, which renders offline. A stretched group restarts when what feeds it changes — a file
            /// or an offset — so a change of mix must reach the backend with the recordings it already had, or every
            /// mute would restart every group.
            ///
            /// Track A is at the reader's transposition and track B 2 semitones up, so each has its own group and pair:
            /// stretchers 0 and 1 are A's, 2 and 3 B's.
            @Suite("PlaybackEngine keeps a recording's mapping across a change of mix")
            @MainActor
            final class PlaybackEngineRecordingIdentityTests {
                private typealias Fixtures = SwiftySynthRecordingRenderTests

                private struct NullResolver: SoundfontResolver {
                    func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
                        nil
                    }

                    var defaultGMSoundfontURL: URL? {
                        nil
                    }
                }

                private let live = RecordingBackend()
                private let engine: PlaybackEngine
                private let fileA: URL
                private let fileB: URL
                private let fileC: URL
                private let recorder = FakeStretcherRecorder()
                /// How many of the engine's track lists were handed on.
                private var forwarded = 0

                init() throws {
                    fileA = try PCMCacheFixture.write(rate: 44100, frames: 44100 * 4) { _ in 6554 }
                    fileB = try PCMCacheFixture.write(rate: 44100, frames: 44100 * 4) { _ in 3277 }
                    fileC = try PCMCacheFixture.write(rate: 44100, frames: 44100 * 4) { _ in 9830 }
                    engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: live)
                    try engine.prepare(score: Self.makeScore())
                }

                deinit {
                    for file in [fileA, fileB, fileC] {
                        try? FileManager.default.removeItem(at: file)
                    }
                }

                private static func makeScore() -> Score {
                    let quarter = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
                    let voice = Voice(elements: [.timeSignature(TimeSignature(numerator: 4, denominator: 4))]
                        + Array(repeating: VoiceElement.chord(quarter), count: 4))
                    let part = Part(
                        id: "p", instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
                        staves: [Staff(measures: [Measure(voices: [voice])])],
                    )
                    return Score(division: 480, parts: [part])
                }

                private func a(file: URL? = nil, offset: Double = 0, volume: Float = 1, muted: Bool = false)
                    -> RecordingTrack
                {
                    RecordingTrack(
                        id: "a", pcmFile: file ?? fileA, offsetSeconds: offset, volume: volume, isMuted: muted,
                    )
                }

                private var b: RecordingTrack {
                    RecordingTrack(id: "b", pcmFile: fileB, transposeSemitones: 2)
                }

                /// The stretching backend, playing at 70 % with the whole of each file heard from warped second 0.
                private func rig() async throws -> Fixtures.Rig {
                    let font = try Fixtures.writeClickSoundFont()
                    defer { try? FileManager.default.removeItem(at: font) }
                    let rig = try await Fixtures.Rig.make(
                        score: Fixtures.silentScore(), font: font, stretcherFactory: recorder.factory,
                    )
                    rig.backend.setRate(0.7)
                    rig.backend.setPlaybackAlignment(warp: nil, segments: Fixtures.wholeRecording(4))
                    return rig
                }

                /// Hands the stretching backend the track list the engine last handed its own, if it handed a new one.
                private func forward(to rig: Fixtures.Rig) {
                    let calls = live.recordingTrackCalls
                    guard calls.count > forwarded, let last = calls.last else { return }
                    forwarded = calls.count
                    rig.backend.setRecordingTracks(last)
                }

                /// Each stretcher's calls other than `process`: a restart (`reset`, `transpose`, `seek`) adds to them.
                private var restartCalls: [Int] {
                    recorder.made.map { stretcher in
                        stretcher.calls.count(where: { if case .process = $0 { false } else { true } })
                    }
                }

                /// Both tracks playing through their pairs for a second.
                private func start() async throws -> Fixtures.Rig {
                    let rig = try await rig()
                    try engine.setRecordingTracks([a(), b])
                    forward(to: rig)
                    rig.backend.play()
                    _ = try rig.render(seconds: 1)
                    try #require(recorder.made.count == 4, "a pair for each group")
                    return rig
                }

                @Test("a mute or a volume change, by track list or by strip, restarts no pair")
                func mixChangesRestartNothing() async throws {
                    let rig = try await start()
                    defer { rig.finish() }
                    let settled = restartCalls
                    let mapped = try #require(live.recordingTrackCalls.last).map(\.recording)

                    try engine.setRecordingTracks([a(muted: true), b])
                    let remapped = try #require(live.recordingTrackCalls.last).map(\.recording)
                    #expect(zip(remapped, mapped).allSatisfy { $0 === $1 }, "both tracks keep their mapping")
                    forward(to: rig)
                    _ = try rig.render(seconds: 0.2)
                    #expect(restartCalls == settled, "A muted by its track list: \(restartCalls) from \(settled)")

                    try engine.setRecordingTracks([a(volume: 0.5), b])
                    forward(to: rig)
                    _ = try rig.render(seconds: 0.2)
                    #expect(restartCalls == settled, "A's volume by its track list: \(restartCalls) from \(settled)")

                    engine.setRecordingMix(id: "b", volume: 0.3, isMuted: true, isSoloed: false)
                    forward(to: rig)
                    _ = try rig.render(seconds: 0.2)
                    #expect(restartCalls == settled, "B's strip: \(restartCalls) from \(settled)")
                    #expect(recorder.made.count == 4, "no new pair")
                }

                @Test("an offset or a file change restarts that track's pair, and only that one")
                func offsetAndFileChangesRestartTheirPair() async throws {
                    let rig = try await start()
                    defer { rig.finish() }
                    let settled = restartCalls

                    try engine.setRecordingTracks([a(offset: 0.5), b])
                    forward(to: rig)
                    _ = try rig.render(seconds: 0.2)
                    let afterOffset = restartCalls
                    #expect(afterOffset[0 ..< 2] != settled[0 ..< 2], "A's pair restarts for its offset")
                    #expect(afterOffset[2 ..< 4] == settled[2 ..< 4], "B's pair carries on: \(afterOffset)")

                    let mapped = try #require(live.recordingTrackCalls.last).map(\.recording)
                    try engine.setRecordingTracks([a(file: fileC, offset: 0.5), b])
                    let remapped = try #require(live.recordingTrackCalls.last).map(\.recording)
                    #expect(remapped[0] !== mapped[0] && remapped[1] === mapped[1], "only A's new file is mapped anew")
                    forward(to: rig)
                    _ = try rig.render(seconds: 0.2)
                    #expect(restartCalls[0 ..< 2] != afterOffset[0 ..< 2], "A's pair restarts for its new file")
                    #expect(restartCalls[2 ..< 4] == settled[2 ..< 4], "B's pair carries on: \(restartCalls)")
                    #expect(recorder.made.count == 4, "no new pair")
                }
            }
        }
    #endif
#endif
