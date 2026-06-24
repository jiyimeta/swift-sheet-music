#if !os(Android)
    import Foundation
    @testable import SheetMusicAudio
    @testable import SheetMusicAudioApple
    @testable import SheetMusicCore
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

            @Test("preview resumes a host-paused engine, then restores the paused state")
            func previewResumesThenRestores() async throws {
                let engine = PlaybackEngine(soundfontResolver: NullResolver())
                let score = makeSingleNoteScore()
                try engine.prepare(score: score)
                engine.pause() // host parks the graph (folino does this right after load)
                #expect(engine.engine.isRunning == false)

                engine.playPreview(noteID: firstNoteID, in: score, duration: 0.05)
                #expect(engine.engine.isRunning == true) // resumed so the note can actually sound

                try await Task.sleep(for: .milliseconds(250)) // let the note-off + drain fire
                #expect(engine.engine.isRunning == false) // restored to the host's paused state
                #expect(engine.state == .paused) // transport state untouched
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
        }
    }
#endif
