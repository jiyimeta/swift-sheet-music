#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import AVFoundation
    #if os(macOS)
        import CoreAudio
    #endif
    import Foundation
    @testable import SheetMusicAudio
    @testable import SheetMusicAudioApple
    import SheetMusicAudioCore
    @testable import SheetMusicCore
    import SheetMusicMIDI
    import Testing

    /// `IdleParkPolicy.deferred`: after the last sound the graph stays warm for the grace instead of being parked at
    /// once, so the next preview or play needs no `AVAudioEngine.start()` — the call that blocks for 0.2–0.55 s on a
    /// Bluetooth output. The grace here is long enough never to elapse during a test; each test fires the pending park
    /// itself with `firePendingIdleParkForTesting()`.
    extension AudioEngineSerial {
        @Suite("PlaybackEngine idle park")
        @MainActor
        struct PlaybackEngineIdleParkTests {
            private struct NullResolver: SoundfontResolver {
                func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
                    nil
                }

                var defaultGMSoundfontURL: URL? {
                    nil
                }
            }

            @MainActor
            private final class FakeBackend: SynthBackendTestDouble {
                let outputNode: AVAudioNode = AVAudioMixerNode()
                private(set) var currentTick = 0
                let currentPositionSeconds: TimeInterval = 0

                func attach(to engine: AVAudioEngine) {
                    engine.attach(outputNode)
                }

                func prepare(
                    soundfontURL _: URL?, metronomeSoundfontURL _: URL?, drumChannels _: Set<UInt8>,
                ) {}
                func loadSequence(_: MidiFile, timeline _: PlaybackTimeline) {}
                func loadMetronomeSequence(_: MidiFile, offsetSeconds _: TimeInterval) {}
                func setMetronomeMuted(_: Bool) {}
                func play() {}
                func pause() {}
                func stop() {}
                func seek(toTick tick: Int) {
                    currentTick = tick
                }

                func setRate(_: Float) {}
                func setTuning(cents _: Double, transposeSemitones _: Int) {}
                func setProgram(channel _: UInt8, program _: UInt8) {}
                func sendVolume(channel _: UInt8, cc7 _: UInt8) {}
                func startNote(channel _: UInt8, pitch _: UInt8, velocity _: UInt8) {}
                func stopNote(channel _: UInt8, pitch _: UInt8) {}
                func teardown() {}
            }

            private static let grace: Duration = .seconds(30)

            private func makeEngine(policy: PlaybackEngine.IdleParkPolicy = .deferred(grace: grace)) -> PlaybackEngine {
                PlaybackEngine(soundfontResolver: NullResolver(), backend: FakeBackend(), idleParkPolicy: policy)
            }

            private func makeSingleNoteScore() -> Score {
                let chord = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
                let voice = Voice(elements: [.chord(chord)])
                let part = Part(
                    id: "lead",
                    instrument: Instrument(id: "piano", channels: [InstrumentChannel(program: 0)]),
                    staves: [Staff(measures: [Measure(voices: [voice])])],
                )
                return Score(division: 480, parts: [part])
            }

            private var firstNoteID: NoteID {
                NoteID(
                    staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                    measureIndex: 0, voiceIndex: 0, elementIndex: 0, noteIndexInChord: 0,
                )
            }

            @Test("pausing playback keeps the graph warm through the grace, then parks it")
            func pauseAfterPlayDefersThePark() throws {
                let engine = makeEngine()
                let score = makeSingleNoteScore()
                try engine.prepare(score: score)
                engine.play(in: score)
                #expect(engine.state == .playing)

                engine.pause()
                #expect(engine.state == .paused)
                #expect(engine.engine.isRunning == true)
                #expect(engine.isIdleParkPending == true)

                engine.firePendingIdleParkForTesting()
                #expect(engine.engine.isRunning == false)
                #expect(engine.isIdleParkPending == false)
                #expect(engine.state == .paused)
            }

            @Test("playing again within the grace cancels the park")
            func playWithinGraceCancelsThePark() throws {
                let engine = makeEngine()
                let score = makeSingleNoteScore()
                try engine.prepare(score: score)
                engine.play(in: score)
                engine.pause()
                #expect(engine.isIdleParkPending == true)

                engine.play(in: score)
                #expect(engine.isIdleParkPending == false)
                #expect(engine.engine.isRunning == true)
                engine.firePendingIdleParkForTesting() // nothing pending — must not park a playing graph
                #expect(engine.engine.isRunning == true)
                engine.pause()
            }

            /// A host parks the graph right after `prepare(score:)` (folino's `didPrepare`). Nothing has sounded, so
            /// opening a score must not hold the output device for the grace.
            @Test("pausing a transport that was not playing parks at once")
            func pauseWithoutPlayParksAtOnce() throws {
                let engine = makeEngine()
                try engine.prepare(score: makeSingleNoteScore())
                #expect(engine.engine.isRunning == true) // `prepare` leaves the graph running

                engine.pause()
                #expect(engine.engine.isRunning == false)
                #expect(engine.isIdleParkPending == false)
            }

            @Test("a tap preview on a parked graph keeps it warm after its drain, then parks")
            func tapPreviewDefersThePark() async throws {
                let engine = makeEngine()
                let score = makeSingleNoteScore()
                try engine.prepare(score: score)
                engine.pause()
                #expect(engine.engine.isRunning == false)

                engine.playPreview(noteID: firstNoteID, in: score, duration: 0.05)
                #expect(engine.engine.isRunning == true)
                try await Task.sleep(for: .milliseconds(250)) // past the note-off
                #expect(engine.engine.isRunning == true)
                #expect(engine.isIdleParkPending == true)

                engine.firePendingIdleParkForTesting()
                #expect(engine.engine.isRunning == false)
                #expect(engine.state == .paused)
            }

            /// The park a paused transport scheduled is cancelled by the preview; the preview must take the park on
            /// itself, or the graph would run until something else parks it.
            @Test("a preview within the grace re-schedules the park after its own drain")
            func previewWithinGraceReschedulesThePark() async throws {
                let engine = makeEngine()
                let score = makeSingleNoteScore()
                try engine.prepare(score: score)
                engine.play(in: score)
                engine.pause()
                #expect(engine.isIdleParkPending == true)

                engine.playPreview(noteID: firstNoteID, in: score, duration: 0.05)
                #expect(engine.isIdleParkPending == false) // sounding — nothing may park it now
                try await Task.sleep(for: .milliseconds(250))
                #expect(engine.isIdleParkPending == true)

                engine.firePendingIdleParkForTesting()
                #expect(engine.engine.isRunning == false)
            }

            @Test("a held preview within the grace re-schedules the park on its note-off")
            func heldPreviewReschedulesTheParkOnNoteOff() throws {
                let engine = makeEngine()
                let score = makeSingleNoteScore()
                try engine.prepare(score: score)
                engine.play(in: score)
                engine.pause()

                engine.previewNoteOn(pitch: 60, onStaff: 0, atTick: 0)
                #expect(engine.isIdleParkPending == false)
                #expect(engine.engine.isRunning == true)

                engine.previewNoteOff(pitch: 60)
                #expect(engine.isIdleParkPending == true)
                #expect(engine.engine.isRunning == true)

                engine.firePendingIdleParkForTesting()
                #expect(engine.engine.isRunning == false)
            }

            /// A hold begun during playback is not a parked graph's to re-park, but the pause that follows schedules
            /// the park — and at its deadline the hold is still sounding.
            @Test("a park whose deadline arrives mid-hold leaves the hold sounding, and the note-off parks")
            func parkAtDeadlineSparesASoundingHold() throws {
                let engine = makeEngine()
                let score = makeSingleNoteScore()
                try engine.prepare(score: score)
                engine.play(in: score)
                engine.previewNoteOn(pitch: 60, onStaff: 0, atTick: 0)
                engine.pause()
                #expect(engine.isIdleParkPending == true)

                engine.firePendingIdleParkForTesting()
                #expect(engine.engine.isRunning == true) // the hold is still sounding

                engine.previewNoteOff(pitch: 60)
                #expect(engine.isIdleParkPending == true)
                engine.firePendingIdleParkForTesting()
                #expect(engine.engine.isRunning == false)
            }

            @Test("prepare drops a park pending from the previous score")
            func prepareDropsAPendingPark() throws {
                let engine = makeEngine()
                let score = makeSingleNoteScore()
                try engine.prepare(score: score)
                engine.play(in: score)
                engine.pause()
                #expect(engine.isIdleParkPending == true)

                try engine.prepare(score: score)
                #expect(engine.isIdleParkPending == false)
                #expect(engine.engine.isRunning == true) // `prepare` leaves the graph running, as without a policy
            }

            @Test("teardown drops a pending park")
            func teardownDropsAPendingPark() throws {
                let engine = makeEngine()
                let score = makeSingleNoteScore()
                try engine.prepare(score: score)
                engine.play(in: score)
                engine.pause()
                #expect(engine.isIdleParkPending == true)

                engine.teardown()
                #expect(engine.isIdleParkPending == false)
                #expect(engine.engine.isRunning == false)
            }

            @Test("the immediate policy parks a paused playback synchronously, as before the policy existed")
            func immediatePolicyParksOnPause() throws {
                let engine = makeEngine(policy: .immediate)
                let score = makeSingleNoteScore()
                try engine.prepare(score: score)
                engine.play(in: score)

                engine.pause()
                #expect(engine.engine.isRunning == false)
                #expect(engine.isIdleParkPending == false)
            }

            #if os(macOS)
                /// `.deferredOnBluetoothOutput` keys off the device the graph plays through. With no device of its own
                /// set, that is the system default output — read here independently through CoreAudio.
                @Test("the Bluetooth check reads the device the graph plays through")
                func bluetoothCheckReadsTheGraphsDevice() throws {
                    let engine = makeEngine()
                    try engine.prepare(score: makeSingleNoteScore())

                    var address = AudioObjectPropertyAddress(
                        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                        mScope: kAudioObjectPropertyScopeGlobal,
                        mElement: kAudioObjectPropertyElementMain,
                    )
                    var device = AudioDeviceID(kAudioObjectUnknown)
                    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
                    let systemObject = AudioObjectID(kAudioObjectSystemObject)
                    try #require(AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &device) == noErr)
                    address.mSelector = kAudioDevicePropertyTransportType
                    var transport: UInt32 = 0
                    size = UInt32(MemoryLayout<UInt32>.size)
                    try #require(AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr)
                    let expected = transport == kAudioDeviceTransportTypeBluetooth
                        || transport == kAudioDeviceTransportTypeBluetoothLE

                    #expect(engine.isOutputBluetooth == expected)
                    engine.teardown()
                }
            #endif
        }
    }
#endif
