#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import AVFoundation
    import Foundation
    @testable import SheetMusicAudio
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    @testable import SheetMusicCore
    @testable import SheetMusicMIDI
    import Testing

    extension AudioEngineSerial {
        @Suite("PlaybackEngine prepared playback")
        @MainActor
        struct PlaybackEnginePreparedPlaybackTests {
            private struct NullResolver: SoundfontResolver {
                func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
                    nil
                }

                var defaultGMSoundfontURL: URL? {
                    nil
                }
            }

            @Test("PreparedPlayback matches the engine's lazy render and timeline")
            func preparedPlaybackMatchesLazyPath() throws {
                let score = makeScore(pitch: 60)
                let prepared = try PreparedPlayback.make(score: score)
                let backend = RecordingBackend()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)

                try engine.prepare(score: score)
                #expect(engine.renderedMidiCache == nil)
                engine.play(in: score)

                #expect(prepared.timeline == backend.timeline)
                #expect(prepared.renderedMidi == engine.renderedMidiCache?.midi)
            }

            @Test("PreparedPlayback stops before work when its task is already cancelled")
            func preparedPlaybackHonorsCancellation() async {
                let score = makeScore(pitch: 60)
                let task = Task { @MainActor in
                    try PreparedPlayback.make(score: score)
                }
                task.cancel()

                do {
                    _ = try await task.value
                    Issue.record("Expected CancellationError")
                } catch is CancellationError {
                    // Expected.
                } catch {
                    Issue.record("Expected CancellationError, got \(error)")
                }
            }

            @Test("prepare remains lazy until first play")
            func prepareLeavesRenderCacheEmpty() throws {
                let score = makeScore(pitch: 60)
                let backend = RecordingBackend()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)

                try engine.prepare(score: score)
                #expect(engine.renderedMidiCache == nil)
                #expect(backend.lastSequence == nil)

                engine.play(in: score)
                #expect(engine.renderedMidiCache != nil)
                #expect(backend.lastSequence != nil)
            }

            @Test("a note edit swaps the cached SMF without preparing the backend again")
            func noteEditUsesFastPath() throws {
                let original = makeScore(pitch: 60)
                let edited = makeScore(pitch: 67)
                let prepared = try PreparedPlayback.make(score: edited)
                let backend = RecordingBackend()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                try engine.prepare(score: original)
                engine.setRate(1.25)
                engine.setMasterTuning(cents: -12.5)
                let instrument = try #require(engine.mixerChannels.first { $0.id != .metronome })
                engine.setVolume(forChannel: instrument.id, to: 0.35)
                engine.setMuted(forChannel: instrument.id, to: true)
                engine.setSoloed(forChannel: instrument.id, to: true)
                engine.setProgram(forChannel: instrument.id, to: 24)
                let prepareCalls = backend.prepareCallCount
                let stopCalls = backend.stopCallCount
                let rateValues = backend.rateValues
                let tuningValues = backend.tuningValues

                let outcome = try engine.replaceScore(with: prepared)

                #expect(outcome == .swappedInPlace)
                #expect(backend.prepareCallCount == prepareCalls)
                #expect(backend.stopCallCount == stopCalls + 1)
                #expect(backend.rateValues == rateValues)
                #expect(backend.tuningValues.map(\.cents) == tuningValues.map(\.cents))
                #expect(backend.tuningValues.map(\.semitones) == tuningValues.map(\.semitones))
                #expect(engine.renderedMidiCache?.midi == prepared.renderedMidi)
                let retained = try #require(engine.mixerChannels.first { $0.id == instrument.id })
                #expect(retained.volume == 0.35)
                #expect(retained.isMuted)
                #expect(retained.isSoloed)
                #expect(retained.program == 24)

                engine.play(in: edited)
                #expect(noteOnPitches(in: backend.lastSequence).contains(67))
                #expect(!noteOnPitches(in: backend.lastSequence).contains(60))
            }

            @Test("a fast replacement keeps the metronome disabled")
            func fastReplacementKeepsMetronomeDisabled() throws {
                let original = makeScore(pitch: 60)
                let edited = makeScore(pitch: 67)
                let backend = RecordingBackend()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                try engine.prepare(score: original)
                engine.setMetronomeEnabled(false)

                let outcome = try engine.replaceScore(
                    with: PreparedPlayback.make(score: edited),
                )

                #expect(outcome == .swappedInPlace)
                #expect(engine.exportEngineSnapshot().metronomeEnabled == false)
                #expect(backend.metronomeMuted == true)
            }

            @Test("an instrument layout edit falls back to full prepare")
            func instrumentEditUsesFullPrepare() throws {
                let original = makeScore(pitch: 60, program: 0)
                let edited = makeScore(pitch: 60, program: 40)
                let backend = RecordingBackend()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                try engine.prepare(score: original)

                let outcome = try engine.replaceScore(
                    with: PreparedPlayback.make(score: edited),
                )

                #expect(outcome == .fullyPrepared)
                #expect(backend.prepareCallCount == 2)
            }

            @Test("replacement without an existing prepare uses full prepare")
            func unpreparedEngineUsesFullPrepare() throws {
                let score = makeScore(pitch: 60)
                let backend = RecordingBackend()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)

                let outcome = try engine.replaceScore(
                    with: PreparedPlayback.make(score: score),
                )

                #expect(outcome == .fullyPrepared)
                #expect(backend.prepareCallCount == 1)
                #expect(engine.loadedScore == score)
            }

            @Test("the AUMIDISynth path always uses full prepare")
            func nonBackendEngineUsesFullPrepare() throws {
                let original = makeScore(pitch: 60)
                let edited = makeScore(pitch: 67)
                let engine = PlaybackEngine(soundfontResolver: NullResolver())
                try engine.prepare(score: original)
                let originalSynth = try #require(engine.melodicSynth)

                try engine.replaceScore(with: PreparedPlayback.make(score: edited))

                #expect(engine.melodicSynth !== originalSynth)
                #expect(engine.loadedScore == edited)
            }

            /// The second quarter of measure 1 sits at tick 1920 + 480. (Element 0 of measure 0 is the time signature,
            /// so a measure's quarters are elements 1–4 there and 0–3 everywhere else.)
            private static let secondQuarterOfMeasureOne = 2400

            @Test("a paused replace stays paused at the same place")
            func pausedReplaceKeepsPosition() throws {
                let original = makeScore(pitch: 60, measureCount: 2)
                let edited = makeScore(pitch: 67, measureCount: 2)
                let backend = RecordingBackend()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                try engine.prepare(score: original)
                engine.play(in: original)
                engine.seek(to: .item(.note(noteID(measureIndex: 1, elementIndex: 1))))
                engine.pause()
                let before = try #require(engine.currentCursor)

                try engine.replaceScore(with: PreparedPlayback.make(score: edited))

                #expect(engine.state == .paused)
                #expect(engine.currentCursor == before)
                // Seated already, so the clock a host reads the time from agrees with the cursor.
                #expect(backend.seekCalls.last == Self.secondQuarterOfMeasureOne)
                #expect(noteOnPitches(in: backend.lastSequence).contains(67))
                engine.play(from: nil, in: edited)
                #expect(backend.seekCalls.last == Self.secondQuarterOfMeasureOne)
            }

            @Test("a playing replace keeps playing from the same place")
            func playingReplaceKeepsPlaying() throws {
                let original = makeScore(pitch: 60, measureCount: 2)
                let edited = makeScore(pitch: 67, measureCount: 2)
                let backend = RecordingBackend()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                try engine.prepare(score: original)
                engine.play(in: original)
                engine.seek(to: .item(.note(noteID(measureIndex: 1, elementIndex: 1))))
                let before = try #require(engine.currentCursor)

                try engine.replaceScore(with: PreparedPlayback.make(score: edited))

                #expect(engine.state == .playing)
                #expect(engine.currentCursor == before)
                #expect(backend.seekCalls.last == Self.secondQuarterOfMeasureOne)
                #expect(noteOnPitches(in: backend.lastSequence).contains(67))
                #expect(!noteOnPitches(in: backend.lastSequence).contains(60))
            }

            @Test("the loop comes back over the same measures")
            func replaceKeepsLoop() throws {
                let original = makeScore(pitch: 60, measureCount: 2)
                let edited = makeScore(pitch: 67, measureCount: 2)
                let backend = RecordingBackend()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                try engine.prepare(score: original)
                engine.play(in: original)
                engine.setLoop(
                    from: .item(.note(noteID(measureIndex: 0, elementIndex: 1))),
                    throughEndOf: .note(noteID(measureIndex: 0, elementIndex: 3)),
                )
                let loop = try #require(engine.loopRange)

                try engine.replaceScore(with: PreparedPlayback.make(score: edited))

                #expect(engine.loopRange == loop)
            }

            @Test("a cursor in a measure the edit removed lands on the start of the last one")
            func removedMeasureClampsCursor() throws {
                let original = makeScore(pitch: 60, measureCount: 3)
                let edited = makeScore(pitch: 60, measureCount: 2)
                let backend = RecordingBackend()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                try engine.prepare(score: original)
                engine.play(in: original)
                engine.seek(to: .item(.note(noteID(measureIndex: 2, elementIndex: 2))))
                engine.pause()

                try engine.replaceScore(with: PreparedPlayback.make(score: edited))

                #expect(engine.state == .paused)
                #expect(backend.seekCalls.last == 1920)
            }

            @Test("an engine that never played stays at the top")
            func unplayedReplaceStaysAtTop() throws {
                let original = makeScore(pitch: 60, measureCount: 2)
                let edited = makeScore(pitch: 67, measureCount: 2)
                let backend = RecordingBackend()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                try engine.prepare(score: original)

                try engine.replaceScore(with: PreparedPlayback.make(score: edited))

                #expect(engine.state == .stopped)
                #expect(engine.currentCursor == nil)
                engine.play(from: nil, in: edited)
                #expect(backend.seekCalls.last == 0)
            }

            /// The graph rebuild's own paused branch, before the SoundFont lands: it kept the cursor but left the
            /// transport stopped, so the next resume started at the top of the piece.
            @Test("a paused rebuild while the SoundFont loads resumes where it paused")
            func pausedRestartWhileLoadingResumesInPlace() throws {
                let score = makeScore(pitch: 60, measureCount: 2)
                let backend = RecordingBackend()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                try engine.prepare(score: score)
                engine.play(in: score)
                engine.seek(to: .item(.note(noteID(measureIndex: 1, elementIndex: 1))))
                engine.pause()
                let before = try #require(engine.currentCursor)
                backend.isReady = false

                try engine.restartGraphPreservingState()

                #expect(engine.state == .paused)
                #expect(engine.currentCursor == before)
                backend.isReady = true
                engine.play(from: nil, in: score)
                #expect(backend.seekCalls.last == Self.secondQuarterOfMeasureOne)
            }

            @Test("a layout change keeps the transport too")
            func fullPrepareKeepsPosition() throws {
                let original = makeScore(pitch: 60, program: 0, measureCount: 2)
                let edited = makeScore(pitch: 60, program: 40, measureCount: 2)
                let backend = RecordingBackend()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                try engine.prepare(score: original)
                engine.play(in: original)
                engine.seek(to: .item(.note(noteID(measureIndex: 1, elementIndex: 1))))
                engine.pause()

                let outcome = try engine.replaceScore(with: PreparedPlayback.make(score: edited))

                #expect(outcome == .fullyPrepared)
                #expect(engine.state == .paused)
                #expect(backend.seekCalls.last == Self.secondQuarterOfMeasureOne)
            }

            @Test("a shifted instrument change keeps the fast path and installs its new tick")
            func shiftedInstrumentChangeSwapsSwitchTable() throws {
                let original = makeInstrumentChangeScore(leadingMeasureCount: 1)
                let shifted = makeInstrumentChangeScore(leadingMeasureCount: 2)
                let prepared = try PreparedPlayback.make(score: shifted)
                let backend = RecordingBackend()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                try engine.prepare(score: original)
                let plan = LiveChannelPlan.build(score: shifted)
                let opening = try UInt8(clamping: #require(plan.strip(partIndex: 0, ordinal: 0)).liveChannel)
                let changed = try UInt8(clamping: #require(plan.strip(partIndex: 0, ordinal: 1)).liveChannel)

                try engine.replaceScore(with: prepared)

                #expect(backend.prepareCallCount == 1)
                #expect(engine.midiChannel(forStaff: 0, atTick: 3839) == opening)
                #expect(engine.midiChannel(forStaff: 0, atTick: 3840) == changed)
            }

            @Test("replacement after teardown falls back to full prepare")
            func teardownClearsFastPathEligibility() throws {
                let original = makeScore(pitch: 60)
                let edited = makeScore(pitch: 67)
                let backend = RecordingBackend()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                try engine.prepare(score: original)
                engine.teardown()

                let outcome = try engine.replaceScore(
                    with: PreparedPlayback.make(score: edited),
                )

                #expect(outcome == .fullyPrepared)
                #expect(backend.prepareCallCount == 2)
                #expect(backend.teardownCallCount == 1)
            }

            @Test("replacement is a no-op while exporting")
            func exportingReplacementNoOps() throws {
                let original = makeScore(pitch: 60)
                let edited = makeScore(pitch: 67)
                let backend = RecordingBackend()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                try engine.prepare(score: original)
                engine.setStateForExport(.exporting)

                let outcome = try engine.replaceScore(
                    with: PreparedPlayback.make(score: edited),
                )

                #expect(outcome == .ignoredWhileExporting)
                #expect(engine.loadedScore == original)
                #expect(backend.prepareCallCount == 1)
                #expect(engine.state == .exporting)
            }

            private func makeScore(
                pitch: Int,
                program: Int = 0,
                measureCount: Int = 1,
            ) -> Score {
                let measures = (0 ..< measureCount).map { index in
                    let timeSignature: [VoiceElement] = index == 0
                        ? [.timeSignature(TimeSignature(numerator: 4, denominator: 4))]
                        : []
                    let quarter = Chord(
                        duration: .quarter,
                        notes: [Note(pitch: pitch, tpc: 14)],
                    )
                    return Measure(voices: [Voice(elements: timeSignature + [
                        .chord(quarter), .chord(quarter), .chord(quarter), .chord(quarter),
                    ])])
                }
                return Score(
                    division: 480,
                    parts: [Part(
                        id: "piano",
                        instrument: Instrument(
                            id: "piano", longName: "Piano",
                            channels: [InstrumentChannel(program: program)],
                        ),
                        staves: [Staff(measures: measures)],
                    )],
                    systemMeasures: IdentifiedArray(
                        Array(repeating: SystemMeasure(), count: measureCount),
                    ),
                )
            }

            private func makeInstrumentChangeScore(leadingMeasureCount: Int) -> Score {
                let changed = Instrument(
                    id: "accordion", longName: "Accordion",
                    channels: [InstrumentChannel(program: 21)],
                )
                var score = makeScore(
                    pitch: 60,
                    measureCount: leadingMeasureCount + 1,
                )
                score.systemMeasures.updateValue(at: leadingMeasureCount) { systemMeasure in
                    systemMeasure.elements = [
                        PositionedSystemElement(
                            position: MeasurePosition(offset: Fraction(numerator: 0, denominator: 1)),
                            element: .instrumentChange(InstrumentChange(
                                text: "Accordion",
                                instrument: changed,
                            )),
                            originalStaff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                        ),
                    ]
                }
                return score
            }

            private func noteID(measureIndex: Int, elementIndex: Int) -> NoteID {
                NoteID(
                    staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                    measureIndex: measureIndex,
                    voiceIndex: 0,
                    elementIndex: elementIndex,
                    noteIndexInChord: 0,
                )
            }

            private func noteOnPitches(in midi: MidiFile?) -> [Int] {
                guard let midi else { return [] }
                return midi.tracks.flatMap { track in
                    track.events.compactMap { event in
                        guard case let .noteOn(_, pitch, velocity) = event.event, velocity > 0 else {
                            return nil
                        }
                        return Int(pitch)
                    }
                }
            }
        }
    }
#endif
