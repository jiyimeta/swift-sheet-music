#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    @preconcurrency import AVFoundation
    import Foundation
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    @testable import SheetMusicCore
    import Testing

    extension AudioEngineSerial {
        /// The engine has to follow the audio route: `AVAudioEngine` stops itself when the I/O configuration
        /// changes (a Mac output-device switch, an iOS route change), and without this observer playback goes
        /// silent while `state` still says `.playing`.
        @Suite("PlaybackEngine configuration change")
        @MainActor
        struct PlaybackEngineConfigurationChangeTests {
            private struct FakeResolver: SoundfontResolver {
                func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
                    nil
                }

                var defaultGMSoundfontURL: URL? {
                    nil
                }
            }

            private static func singleStaffScore() -> Score {
                let part = Part(
                    id: "p",
                    instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
                    staves: [Staff(measures: [Measure(voices: [])])],
                )
                return Score(division: 480, parts: [part])
            }

            @Test("a configuration change while playing rebuilds the graph and keeps playing")
            func restartsWhilePlaying() throws {
                let engine = PlaybackEngine(soundfontResolver: FakeResolver())
                let score = Self.singleStaffScore()
                try engine.prepare(score: score)
                engine.play(from: nil, in: score)
                #expect(engine.state == .playing)

                engine.performConfigurationChangeRestart()

                #expect(engine.graphRestartCount == 1)
                #expect(engine.state == .playing)
                #expect(engine.engine.isRunning)
                engine.teardown()
            }

            @Test("a configuration change while paused rebuilds and stays paused at its cursor")
            func restartsWhilePaused() throws {
                let engine = PlaybackEngine(soundfontResolver: FakeResolver())
                let score = Self.singleStaffScore()
                try engine.prepare(score: score)
                engine.play(from: nil, in: score)
                engine.pause()
                let before = try #require(engine.currentCursor)

                engine.performConfigurationChangeRestart()

                #expect(engine.graphRestartCount == 1)
                #expect(engine.state == .paused)
                #expect(engine.currentCursor == before)
                engine.teardown()
            }

            @Test("a configuration change while stopped does nothing")
            func ignoredWhileStopped() throws {
                let engine = PlaybackEngine(soundfontResolver: FakeResolver())
                try engine.prepare(score: Self.singleStaffScore())
                #expect(engine.state == .stopped)

                engine.performConfigurationChangeRestart()

                #expect(engine.graphRestartCount == 0)
                #expect(engine.state == .stopped)
            }

            @Test("a configuration change during an export is ignored")
            func ignoredWhileExporting() throws {
                let engine = PlaybackEngine(soundfontResolver: FakeResolver())
                let score = Self.singleStaffScore()
                try engine.prepare(score: score)
                engine.play(from: nil, in: score)
                engine.setStateForExport(.exporting)

                engine.performConfigurationChangeRestart()

                #expect(engine.graphRestartCount == 0)
                #expect(engine.state == .exporting)
                engine.setStateForExport(.stopped)
                engine.teardown()
            }

            @Test("a failed rebuild stops claiming to play and records the error")
            func failedRestartIsRecorded() throws {
                struct Boom: Error {}
                let engine = PlaybackEngine(soundfontResolver: FakeResolver())
                let score = Self.singleStaffScore()
                try engine.prepare(score: score)
                engine.play(from: nil, in: score)
                engine.graphRestartFailureForTesting = Boom()

                engine.performConfigurationChangeRestart()

                #expect(engine.state == .stopped)
                #expect(engine.lastGraphRestartError is Boom)
                engine.teardown()
            }

            /// The registration itself is what this proves. Every other test in this suite calls the handler
            /// directly and would keep passing if `startObservingConfigurationChanges()` were never called.
            @Test("the real notification reaches the engine, and a burst collapses into one rebuild")
            func realNotificationRestartsOnceForABurst() async throws {
                let engine = PlaybackEngine(soundfontResolver: FakeResolver())
                let score = Self.singleStaffScore()
                try engine.prepare(score: score)
                engine.play(from: nil, in: score)

                // Two posts, as a device switch can produce: the first schedules the rebuild, the second lands
                // on the main queue before that scheduled task runs and is coalesced into it.
                NotificationCenter.default.post(
                    name: .AVAudioEngineConfigurationChange, object: engine.engine,
                )
                NotificationCenter.default.post(
                    name: .AVAudioEngineConfigurationChange, object: engine.engine,
                )
                try await Task.sleep(for: .milliseconds(200))

                #expect(engine.graphRestartCount == 1)
                #expect(engine.state == .playing)
                engine.teardown()
            }
        }
    }
#endif
