#if !os(Android)
    import AVFoundation
    import Foundation
    @testable import SheetMusicAudio
    @testable import SheetMusicAudioApple
    import SheetMusicAudioCore
    @testable import SheetMusicCore
    import SheetMusicMIDI
    import Testing

    /// `playPreview` must be able to sound a note even when the host has parked the audio graph (a paused
    /// `AVAudioEngine` renders nothing). It should resume the engine for the preview, then restore the host's
    /// paused state once the preview ends — without disturbing an engine that is actively playing.
    extension AudioEngineSerial {
        @Suite("PlaybackEngine preview engine resume")
        @MainActor
        struct PlaybackEnginePreviewResumeTests {
            private struct NullResolver: SoundfontResolver {
                func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
                    nil
                }

                var defaultGMSoundfontURL: URL? {
                    nil
                }
            }

            /// Records every `startNote` / `stopNote` call so backend-delegation
            /// tests can assert on the exact sequence without depending on real
            /// synth audio. Every other `SynthBackend` member is a no-op stub.
            private enum NoteEvent: Equatable {
                case on(channel: UInt8, pitch: UInt8, velocity: UInt8)
                case off(channel: UInt8, pitch: UInt8)
            }

            private struct ProgramCall: Equatable {
                let channel: UInt8
                let program: UInt8
            }

            private struct VolumeCall: Equatable {
                let channel: UInt8
                let cc7: UInt8
            }

            @MainActor
            private final class FakeBackend: SynthBackend {
                private(set) var events: [NoteEvent] = []
                private(set) var programCalls: [ProgramCall] = []
                private(set) var volumeCalls: [VolumeCall] = []
                let outputNode: AVAudioNode = AVAudioMixerNode()
                private(set) var currentTick = 0
                let currentPositionSeconds: TimeInterval = 0

                /// Clear everything recorded so far — used to ignore the program /
                /// volume the `prepare` / mixer-setup phase emits, so a test can
                /// assert only on what a subsequent preview re-applies.
                func resetRecording() {
                    events.removeAll()
                    programCalls.removeAll()
                    volumeCalls.removeAll()
                }

                func attach(to engine: AVAudioEngine) {
                    engine.attach(outputNode)
                }

                func prepare(soundfontURL _: URL?, drumChannels _: Set<UInt8>) {}
                func loadSequence(_: MidiFile, timeline _: PlaybackTimeline) {}
                func loadMetronomeSequence(_: MidiFile) {}
                func setMetronomeMuted(_: Bool) {}
                func play() {}
                func pause() {}
                func stop() {}
                func seek(toTick tick: Int) {
                    currentTick = tick
                }

                func setRate(_: Float) {}
                func setTuning(cents _: Double, transposeSemitones _: Int) {}
                func setProgram(channel: UInt8, program: UInt8) {
                    programCalls.append(ProgramCall(channel: channel, program: program))
                }

                func sendVolume(channel: UInt8, cc7: UInt8) {
                    volumeCalls.append(VolumeCall(channel: channel, cc7: cc7))
                }

                func startNote(channel: UInt8, pitch: UInt8, velocity: UInt8) {
                    events.append(.on(channel: channel, pitch: pitch, velocity: velocity))
                }

                func stopNote(channel: UInt8, pitch: UInt8) {
                    events.append(.off(channel: channel, pitch: pitch))
                }

                func teardown() {}
            }

            private func makeSingleNoteScore() -> Score {
                let chord = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
                let voice = Voice(elements: [.chord(chord)])
                let part = Part(
                    id: "lead",
                    instrument: Instrument(
                        id: "piano", channels: [InstrumentChannel(program: 0)],
                    ),
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

            /// The release-tail deferral is a BACKEND-path behavior (`backendPlayPreview`
            /// schedules the park `previewReleaseTail` after the note-off), so this test
            /// must inject a backend. The AU instrument path deliberately has no deferral
            /// — it releases cleanly through an engine pause (see `previewReleaseTail`'s
            /// doc comment) — and is covered by the immediate-repark test below.
            @Test("preview resumes a host-paused engine, then restores the paused state after the release tail (backend path)")
            func previewResumesThenRestores() async throws {
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: FakeBackend())
                let score = makeSingleNoteScore()
                try engine.prepare(score: score)
                engine.pause() // host parks the graph (folino does this right after load)
                #expect(engine.engine.isRunning == false)

                engine.playPreview(noteID: firstNoteID, in: score, duration: 0.05)
                #expect(engine.engine.isRunning == true) // resumed so the note can actually sound

                // The park is deferred past the note-off so the release tail renders out
                // (pausing mid-release would click and freeze the tail), so shortly after
                // the note-off the engine is still running...
                try await Task.sleep(for: .milliseconds(250))
                #expect(engine.engine.isRunning == true)

                // ...and only restored to the host's paused state once the release tail elapses.
                try await Task.sleep(for: .milliseconds(1000))
                #expect(engine.engine.isRunning == false) // restored to the host's paused state
                #expect(engine.state == .paused) // transport state untouched
            }

            /// The AU instrument path parks the engine at the preview's end with no
            /// release-tail deferral — the AU path released cleanly through an engine
            /// pause, so deferring there would only delay the host's parked state.
            @Test("preview resumes a host-paused engine and re-parks it right after the preview ends (AU path)")
            func previewResumesThenReparksImmediatelyOnAUPath() async throws {
                let engine = PlaybackEngine(soundfontResolver: NullResolver())
                let score = makeSingleNoteScore()
                try engine.prepare(score: score)
                engine.pause() // host parks the graph
                #expect(engine.engine.isRunning == false)

                engine.playPreview(noteID: firstNoteID, in: score, duration: 0.05)
                #expect(engine.engine.isRunning == true) // resumed so the note can actually sound

                // The drain fires at +duration and re-parks immediately — no deferral here.
                try await Task.sleep(for: .milliseconds(250))
                #expect(engine.engine.isRunning == false) // restored to the host's paused state
                #expect(engine.state == .paused) // transport state untouched
            }

            @Test("a tap preview re-asserts the staff's mixer program + volume before the note-on")
            func tapPreviewReassertsChannelStateBeforeNote() throws {
                let backend = FakeBackend()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                let score = makeSingleNoteScore()
                try engine.prepare(score: score)
                let channel = try #require(engine.midiChannel(forStaff: 0))

                // A prior playback resets the synth's channels to GM defaults, so an
                // audition — which drives the synth directly, not via the sequencer —
                // must re-push the mixer's program + volume before sounding. Choose
                // non-default values, then drop the calls `prepare` / the setters emit.
                engine.setProgram(forChannel: .staff(0), to: 42)
                engine.setVolume(forChannel: .staff(0), to: 0.5)
                backend.resetRecording()

                engine.playPreview(noteID: firstNoteID, in: score, duration: 0.05)

                #expect(backend.programCalls == [ProgramCall(channel: channel, program: 42)])
                #expect(backend.volumeCalls == [VolumeCall(channel: channel, cc7: 64)]) // round(0.5 * 127)
                #expect(backend.events.first == .on(channel: channel, pitch: 60, velocity: 96))
            }

            @Test("previewNoteOn re-asserts the staff's mixer program + volume before the held note")
            func sustainedPreviewReassertsChannelStateBeforeNote() throws {
                let backend = FakeBackend()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                let score = makeSingleNoteScore()
                try engine.prepare(score: score)
                let channel = try #require(engine.midiChannel(forStaff: 0))

                engine.setProgram(forChannel: .staff(0), to: 42)
                engine.setVolume(forChannel: .staff(0), to: 0.5)
                backend.resetRecording()

                engine.previewNoteOn(pitch: 60, onStaff: 0)

                #expect(backend.programCalls == [ProgramCall(channel: channel, program: 42)])
                #expect(backend.volumeCalls == [VolumeCall(channel: channel, cc7: 64)])
                #expect(backend.events == [.on(channel: channel, pitch: 60, velocity: 96)])

                engine.previewNoteOff(pitch: 60) // clean up
            }

            @Test("preview does not pause an actively-playing engine")
            func previewWhilePlayingKeepsRunning() async throws {
                let engine = PlaybackEngine(soundfontResolver: NullResolver())
                let score = makeSingleNoteScore()
                try engine.prepare(score: score)
                engine.play(in: score)
                #expect(engine.engine.isRunning == true)

                engine.playPreview(noteID: firstNoteID, in: score, duration: 0.05)
                try await Task.sleep(for: .milliseconds(250))
                #expect(engine.engine.isRunning == true) // drain must never pause a playing engine
                engine.pause()
            }

            @Test("previewNoteOn holds a note until previewNoteOff — no auto note-off timer")
            func sustainedHoldRingsUntilExplicitNoteOff() async throws {
                let engine = PlaybackEngine(soundfontResolver: NullResolver())
                let score = makeSingleNoteScore()
                try engine.prepare(score: score)
                engine.pause() // host parks the graph
                #expect(engine.engine.isRunning == false)

                engine.previewNoteOn(pitch: 60, onStaff: 0)
                #expect(engine.engine.isRunning == true) // resumed so the note can actually sound

                // Far longer than any fixed-duration tap preview (0.3 s default / 2 s drum tail).
                try await Task.sleep(for: .milliseconds(500))
                #expect(engine.engine.isRunning == true) // still held — sustained preview has no timer

                engine.previewNoteOff(pitch: 60)
                #expect(engine.engine.isRunning == false) // restored to the host's paused state
                #expect(engine.state == .paused)
            }

            @Test("previewNoteOff with a mismatched pitch is a no-op")
            func mismatchedPitchNoteOffLeavesNoteHeld() throws {
                let engine = PlaybackEngine(soundfontResolver: NullResolver())
                let score = makeSingleNoteScore()
                try engine.prepare(score: score)
                engine.pause()

                engine.previewNoteOn(pitch: 60, onStaff: 0)
                #expect(engine.engine.isRunning == true)

                engine.previewNoteOff(pitch: 61) // not the held pitch — must not cut it
                #expect(engine.engine.isRunning == true)
                #expect(engine.state == .paused)

                engine.previewNoteOff(pitch: 60) // clean up
                #expect(engine.engine.isRunning == false)
            }

            /// The original §5 hardening test never parked the engine and never waited for the tap's
            /// drain to actually fire, so it would still pass even if the `previewGeneration` bump in
            /// `previewNoteOn` were deleted. This variant parks the engine and sleeps past the tap's
            /// duration so the drain genuinely runs (and must find itself invalidated / a no-op).
            @Test("a tap preview's drain does not pause the engine mid-hold (§5 hardening, timed)")
            func tapPreviewDrainDoesNotPauseDuringHold() async throws {
                let engine = PlaybackEngine(soundfontResolver: NullResolver())
                let score = makeSingleNoteScore()
                try engine.prepare(score: score)
                engine.pause() // host parks the graph

                engine.playPreview(noteID: firstNoteID, in: score, duration: 0.05)
                engine.previewNoteOn(pitch: 60, onStaff: 0)
                #expect(engine.engine.isRunning == true)

                try await Task.sleep(for: .milliseconds(250)) // let the tap's drain fire (must no-op)
                #expect(engine.engine.isRunning == true) // hold must still be sounding — no stray pause

                engine.previewNoteOff(pitch: 60)
                #expect(engine.engine.isRunning == false) // now restored to the host's paused state
                #expect(engine.state == .paused)
            }

            /// The reverse ordering: a tap preview fired WHILE a sustained note is held. The tap's
            /// generation is valid (nothing invalidates it), so its drain actually runs at +duration —
            /// it must recognize the still-active hold and skip the repause, leaving that obligation to
            /// `previewNoteOff`. Guards the bug where the drain paused the engine out from under a held
            /// note and consumed the flag, leaving `previewNoteOff` with nothing to restore.
            @Test("a tap preview fired during a held note does not pause the engine on its own drain")
            func tapPreviewDuringHoldDoesNotPauseOnItsOwnDrain() async throws {
                let engine = PlaybackEngine(soundfontResolver: NullResolver())
                let score = makeSingleNoteScore()
                try engine.prepare(score: score)
                engine.pause() // host parks the graph

                engine.previewNoteOn(pitch: 60, onStaff: 0)
                #expect(engine.engine.isRunning == true)

                engine.playPreview(noteID: firstNoteID, in: score, duration: 0.05)
                try await Task.sleep(for: .milliseconds(250)) // let the tap's own drain fire

                #expect(engine.engine.isRunning == true) // the hold is still sounding — must not pause
                #expect(engine.state == .paused) // transport state untouched throughout

                engine.previewNoteOff(pitch: 60)
                #expect(engine.engine.isRunning == false) // released — now restored to the paused state
            }

            @Test("previewNoteOn/Off delegate to the backend on the staff's MIDI channel")
            func backendDelegatesStartAndStopNote() throws {
                let backend = FakeBackend()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                let score = makeSingleNoteScore()
                try engine.prepare(score: score)
                let channel = try #require(engine.midiChannel(forStaff: 0))

                engine.previewNoteOn(pitch: 60, onStaff: 0)
                #expect(backend.events == [.on(channel: channel, pitch: 60, velocity: 96)])

                engine.previewNoteOff(pitch: 60)
                #expect(backend.events == [
                    .on(channel: channel, pitch: 60, velocity: 96),
                    .off(channel: channel, pitch: 60),
                ])
            }

            @Test("a superseding previewNoteOn stops the prior sustained note first")
            func supersedingPreviewNoteOnStopsPriorNote() throws {
                let backend = FakeBackend()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                let score = makeSingleNoteScore()
                try engine.prepare(score: score)
                let channel = try #require(engine.midiChannel(forStaff: 0))

                engine.previewNoteOn(pitch: 60, onStaff: 0)
                engine.previewNoteOn(pitch: 64, onStaff: 0)

                #expect(backend.events == [
                    .on(channel: channel, pitch: 60, velocity: 96),
                    .off(channel: channel, pitch: 60),
                    .on(channel: channel, pitch: 64, velocity: 96),
                ])
            }

            @Test("previewNoteOn cuts a still-pending tap preview before holding (§5 hardening)")
            func previewNoteOnCutsPendingTapPreview() throws {
                let backend = FakeBackend()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                let score = makeSingleNoteScore()
                try engine.prepare(score: score)
                let channel = try #require(engine.midiChannel(forStaff: 0))

                // Long duration so the tap preview's own drain can't fire during this test.
                engine.playPreview(noteID: firstNoteID, in: score, duration: 5.0)
                #expect(backend.events == [.on(channel: channel, pitch: 60, velocity: 96)])

                engine.previewNoteOn(pitch: 64, onStaff: 0)
                #expect(backend.events == [
                    .on(channel: channel, pitch: 60, velocity: 96),
                    .off(channel: channel, pitch: 60),
                    .on(channel: channel, pitch: 64, velocity: 96),
                ])
            }
        }
    }
#endif
