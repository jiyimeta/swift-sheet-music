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

            /// Poll `engine.graphRestartCount` every ~20 ms up to a 2 s deadline, instead of a fixed sleep. A real
            /// notification is delivered asynchronously (off-main-thread post, or the 250 ms debounce), so a fixed
            /// wait either flakes short or wastes time long; polling waits exactly as long as needed and no
            /// longer. The 2 s deadline comfortably exceeds the 250 ms debounce interval.
            private static func waitForGraphRestart(
                atLeast expected: Int, on engine: PlaybackEngine,
            ) async throws {
                let deadline = Duration.seconds(2)
                let step = Duration.milliseconds(20)
                var waited = Duration.zero
                while engine.graphRestartCount < expected, waited < deadline {
                    try await Task.sleep(for: step)
                    waited += step
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

            /// One 4/4 measure of four quarter notes at division 480 — real note content, so `setLoop` has
            /// something to resolve two distinct ticks against (`singleStaffScore()`'s empty measure has none).
            private static func fourQuarterScore() -> Score {
                let quarter = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
                let voice = Voice(elements: [
                    .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                    .chord(quarter), .chord(quarter), .chord(quarter), .chord(quarter),
                ])
                let part = Part(
                    id: "p",
                    instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
                    staves: [Staff(measures: [Measure(voices: [voice])])],
                )
                return Score(division: 480, parts: [part])
            }

            /// Element indices are into `voice.elements`, so the time signature at index 0 shifts the four
            /// chords to 1...4.
            private static func noteID(elementIndex: Int) -> NoteID {
                NoteID(
                    staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                    measureIndex: 0, voiceIndex: 0,
                    elementIndex: elementIndex, noteIndexInChord: 0,
                )
            }

            @Test("a configuration change while playing rebuilds the graph and keeps playing")
            func restartsWhilePlaying() throws {
                let engine = PlaybackEngine(soundfontResolver: FakeResolver())
                let score = Self.singleStaffScore()
                try engine.prepare(score: score)
                engine.play(from: nil, in: score)
                #expect(engine.state == .playing)

                // The real precondition this handler fires under: `AVAudioEngine` has already stopped ITSELF by
                // the time the notification arrives (that's the whole reason the observer exists), not merely
                // that the transport still thinks it's playing.
                engine.engine.stop()

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

                // Two posts, as a device switch can produce: both fall inside the 250 ms trailing debounce
                // window and collapse into one rebuild.
                NotificationCenter.default.post(
                    name: .AVAudioEngineConfigurationChange, object: engine.engine,
                )
                NotificationCenter.default.post(
                    name: .AVAudioEngineConfigurationChange, object: engine.engine,
                )
                try await Self.waitForGraphRestart(atLeast: 1, on: engine)

                #expect(engine.graphRestartCount == 1)
                #expect(engine.state == .playing)
                engine.teardown()
            }

            @Test("a single real notification still rebuilds")
            func realNotificationRestartsOnce() async throws {
                let engine = PlaybackEngine(soundfontResolver: FakeResolver())
                let score = Self.singleStaffScore()
                try engine.prepare(score: score)
                engine.play(from: nil, in: score)

                NotificationCenter.default.post(
                    name: .AVAudioEngineConfigurationChange, object: engine.engine,
                )
                try await Self.waitForGraphRestart(atLeast: 1, on: engine)

                #expect(engine.graphRestartCount == 1)
                #expect(engine.state == .playing)
                engine.teardown()
            }

            /// The case the pre-debounce code got wrong: notifications tens to hundreds of milliseconds apart
            /// (realistic for a device switch reconfiguring in stages) still collapse to one rebuild, because
            /// each post restarts a 250 ms trailing window rather than only coalescing posts that land while a
            /// rebuild is already scheduled.
            @Test("two posts ~50 ms apart still collapse into one rebuild")
            func burstFiftyMillisecondsApartCollapsesToOneRebuild() async throws {
                let engine = PlaybackEngine(soundfontResolver: FakeResolver())
                let score = Self.singleStaffScore()
                try engine.prepare(score: score)
                engine.play(from: nil, in: score)

                NotificationCenter.default.post(
                    name: .AVAudioEngineConfigurationChange, object: engine.engine,
                )
                try await Task.sleep(for: .milliseconds(50))
                NotificationCenter.default.post(
                    name: .AVAudioEngineConfigurationChange, object: engine.engine,
                )
                try await Self.waitForGraphRestart(atLeast: 1, on: engine)

                #expect(engine.graphRestartCount == 1)
                #expect(engine.state == .playing)
                engine.teardown()
            }

            @Test("a rebuild preserves an active loop region")
            func restartPreservesLoop() throws {
                let engine = PlaybackEngine(soundfontResolver: FakeResolver())
                let score = Self.fourQuarterScore()
                try engine.prepare(score: score)
                engine.play(in: score)
                #expect(engine.state == .playing)

                let firstNote = Self.noteID(elementIndex: 1)
                let lastNote = Self.noteID(elementIndex: 4)
                engine.setLoop(from: .item(.note(firstNote)), throughEndOf: .note(lastNote))
                let loop = try #require(engine.loopRange)

                // `prepare(score:)` — called from inside the rebuild — calls `clearLoop()` on its own; this is
                // the regression the fix closes: an automatic rebuild must not silently drop a loop the user is
                // actively practicing against, unlike `prepare(score:)` called directly by the host.
                engine.performConfigurationChangeRestart()

                #expect(engine.graphRestartCount == 1)
                #expect(engine.loopRange == loop)
                #expect(engine.state == .playing)
                engine.teardown()
            }
        }
    }
#endif
