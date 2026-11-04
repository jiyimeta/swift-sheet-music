#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAudio
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    @testable import SheetMusicCore
    import Testing

    /// A tap on a beat sounds everything that starts there as one audition: every note strikes, and the next tap cuts
    /// every one of them.
    extension AudioEngineSerial {
        @Suite("PlaybackEngine onset audition")
        @MainActor
        struct PlaybackEngineOnsetPreviewTests {
            private struct NullResolver: SoundfontResolver {
                func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
                    nil
                }

                var defaultGMSoundfontURL: URL? {
                    nil
                }
            }

            private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

            /// One staff, two voices: voice 1 an E–G dyad then a rest, voice 2 a C then an A.
            private func makeScore() -> Score {
                let upper = Voice(elements: [
                    .timeSignature(TimeSignature(numerator: 2, denominator: 4)),
                    .chord(Chord(duration: .quarter, notes: [Note(pitch: 64, tpc: 18), Note(pitch: 67, tpc: 15)])),
                    .chord(Chord(duration: .quarter, notes: [])),
                ])
                let lower = Voice(elements: [
                    .chord(Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])),
                    .chord(Chord(duration: .quarter, notes: [Note(pitch: 69, tpc: 17)])),
                ])
                let staff = Staff(measures: [Measure(voices: [upper, lower])])
                return Score(division: 480, parts: [Part(id: "p0", instrument: Instrument(id: "i"), staves: [staff])])
            }

            private func setUp() throws -> (RecordingBackend, PlaybackEngine, Score) {
                let backend = RecordingBackend()
                let score = makeScore()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                try engine.prepare(score: score)
                return (backend, engine, score)
            }

            private func struck(_ backend: RecordingBackend) -> [UInt8] {
                backend.liveEvents.compactMap { event in
                    if case let .noteOn(_, pitch) = event { pitch } else { nil }
                }
            }

            @Test("every note of the beat strikes, across both voices")
            func everyNoteStrikes() throws {
                let (backend, engine, score) = try setUp()
                let beat = score.onsetNoteIDs(of: .note(NoteID(
                    staff: Self.staff, measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0,
                )))
                engine.playPreview(noteIDs: beat, in: score)
                #expect(struck(backend) == [64, 67, 60])
            }

            @Test("a rest on a beat the other voice fills sounds that voice")
            func restSoundsTheOtherVoice() throws {
                let (backend, engine, score) = try setUp()
                let beat = score.onsetNoteIDs(of: .rest(RestID(
                    staff: Self.staff, measureIndex: 0, voiceIndex: 0, elementIndex: 2,
                )))
                engine.playPreview(noteIDs: beat, in: score)
                #expect(struck(backend) == [69])
            }

            @Test("the next audition cuts every note of the last one")
            func nextAuditionCutsTheWholeBeat() throws {
                let (backend, engine, score) = try setUp()
                let beat = score.onsetNoteIDs(of: .note(NoteID(
                    staff: Self.staff, measureIndex: 0, voiceIndex: 1, elementIndex: 0, noteIndexInChord: 0,
                )))
                engine.playPreview(noteIDs: beat, in: score)
                engine.playPreview(noteID: NoteID(
                    staff: Self.staff, measureIndex: 0, voiceIndex: 1, elementIndex: 1, noteIndexInChord: 0,
                ), in: score)
                #expect(backend.stoppedNotes.map(\.pitch).sorted() == [60, 64, 67])
                #expect(struck(backend) == [64, 67, 60, 69])
            }

            @Test("a beat that resolves to nothing leaves the ringing audition alone")
            func emptyBeatCutsNothing() throws {
                let (backend, engine, score) = try setUp()
                engine.playPreview(noteID: NoteID(
                    staff: Self.staff, measureIndex: 0, voiceIndex: 1, elementIndex: 0, noteIndexInChord: 0,
                ), in: score)
                engine.playPreview(noteIDs: [], in: score)
                #expect(backend.stoppedNotes.isEmpty)
                #expect(struck(backend) == [60])
            }
        }
    }
#endif
