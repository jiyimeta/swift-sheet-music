#if !os(Android)
    import AVFoundation
    import Foundation
    @testable import SheetMusicAudio
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    @testable import SheetMusicCore
    import SheetMusicMIDI
    import Testing

    /// Regression tests for the count-in on the injected-backend (`SwiftySynthBackend`) path,
    /// covering two bugs a host reported together — no count-in at all with "repeat whole
    /// score" on, and a count-in that clicked with the score font's GM wood block instead of
    /// the host's click samples.
    ///
    /// Both came from the same decision: the backend path used to shift the SCORE SMF behind a
    /// click track baked into it. That put the click on the score synth (the metronome synth is
    /// the one holding the click SoundFont), and it made every score-tick read speak a shifted
    /// coordinate space — so a count-in was simply suppressed whenever a loop was active, which
    /// "repeat whole score" always is.
    ///
    /// Now the score SMF is never shifted and the count lives on the metronome transport, which
    /// the backend starts ahead of the score.
    extension AudioEngineSerial {
        @Suite("PlaybackEngine backend count-in")
        @MainActor
        struct PlaybackEngineBackendCountInTests {
            private struct NullResolver: SoundfontResolver {
                func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
                    nil
                }

                var defaultGMSoundfontURL: URL? {
                    nil
                }
            }

            /// Two 4/4 measures of quarter notes at division 480 — enough for a count-in to have
            /// a full measure of its own in front of the start.
            private func makeScore() -> Score {
                let quarter = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
                let first = Voice(elements: [
                    .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                    .chord(quarter), .chord(quarter), .chord(quarter), .chord(quarter),
                ])
                let second = Voice(elements: [
                    .chord(quarter), .chord(quarter), .chord(quarter), .chord(quarter),
                ])
                let part = Part(
                    id: "p",
                    instrument: Instrument(id: "i", channels: [InstrumentChannel(program: 0)]),
                    staves: [Staff(measures: [
                        Measure(voices: [first]), Measure(voices: [second]),
                    ])],
                )
                return Score(division: 480, parts: [part])
            }

            private func noteID(measureIndex: Int, elementIndex: Int) -> NoteID {
                NoteID(
                    staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                    measureIndex: measureIndex, voiceIndex: 0,
                    elementIndex: elementIndex, noteIndexInChord: 0,
                )
            }

            /// Clicks are note-ons on MIDI channel 9 (the GM percussion convention every
            /// backend's metronome uses).
            private func clickTicks(in midi: MidiFile?) -> [Int] {
                guard let midi else { return [] }
                return midi.tracks.flatMap { track in
                    track.events.compactMap { event -> Int? in
                        guard case let .noteOn(channel, _, velocity) = event.event,
                              channel == 9, velocity > 0
                        else { return nil }
                        return event.tick
                    }
                }.sorted()
            }

            @Test("a count-in still counts with a whole-score loop active")
            func countInSurvivesAnActiveLoop() throws {
                let backend = RecordingBackend()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                let score = makeScore()
                try engine.prepare(score: score)

                // Exactly what folino's `.loopAll` repeat mode pushes into the engine.
                engine.setLoop(
                    from: .item(.note(noteID(measureIndex: 0, elementIndex: 1))),
                    throughEndOf: .note(noteID(measureIndex: 1, elementIndex: 3)),
                )
                #expect(engine.loopRange != nil)

                engine.play(from: nil, in: score, countIn: true)

                // A loop must not suppress the count-in — the whole-score repeat is on for most
                // of a practice session, which is exactly when a count is wanted.
                let seconds = try #require(backend.countInSeconds)
                #expect(seconds > 0)
                #expect(engine.state == .playing)
            }

            @Test("the count-in's clicks go to the metronome transport, not the score's")
            func countInClicksLiveOnTheMetronomeSequence() throws {
                let backend = RecordingBackend()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                let score = makeScore()
                try engine.prepare(score: score)

                engine.play(from: nil, in: score, countIn: true)

                let preRollSeconds = try #require(backend.countInSeconds)
                // The score SMF carries no clicks at all: it is the plain body, and the score
                // synth has the score's SoundFont — a click written here sounds as GM wood block.
                #expect(clickTicks(in: backend.lastSequence).isEmpty)
                // The metronome SMF opens with the count itself, ahead of the body's own beats.
                let ticks = clickTicks(in: backend.lastMetronomeSequence)
                #expect(ticks.first == 0)
                #expect(ticks.count >= 4)
                // A 4/4 measure at the score's tempo — the count the host hears before the piece.
                #expect(abs(preRollSeconds - 2.0) < 0.001)
                // Playing from the top: the body starts at score 0, a whole pre-roll into the
                // metronome's own clock.
                #expect(abs(backend.metronomeOffsetSeconds - preRollSeconds) < 0.001)
            }

            @Test("a plain play after a count-in drops the pre-roll clicks again")
            func plainPlayReloadsThePlainMetronomeSequence() throws {
                let backend = RecordingBackend()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                let score = makeScore()
                try engine.prepare(score: score)

                engine.play(from: nil, in: score, countIn: true)
                engine.stop()
                engine.play(from: nil, in: score, countIn: false)

                #expect(backend.countInSeconds == nil)
                #expect(backend.metronomeOffsetSeconds == 0)
                // The body's first beat is at tick 0; what must be gone is the count in front of
                // it, i.e. the sequence no longer starts a whole pre-roll early.
                let ticks = clickTicks(in: backend.lastMetronomeSequence)
                #expect(ticks.first == 0)
                #expect(ticks.count == 8)
            }
        }
    }
#endif
