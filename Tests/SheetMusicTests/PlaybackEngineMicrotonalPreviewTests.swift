#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAudio
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    @testable import SheetMusicCore
    @testable import SheetMusicMIDI
    import Testing

    /// A clicked microtonal note is heard where it plays: the audition sets the staff channel's pitch wheel to the
    /// accidental's offset before the key, and nothing it leaves behind detunes the score.
    extension AudioEngineSerial {
        @Suite("PlaybackEngine microtonal audition")
        @MainActor
        struct PlaybackEngineMicrotonalPreviewTests {
            private struct NullResolver: SoundfontResolver {
                func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
                    nil
                }

                var defaultGMSoundfontURL: URL? {
                    nil
                }
            }

            /// One staff: a quarter-tone-flat B, a plain C, a three-quarter-tone-flat B.
            private func makeScore() -> Score {
                let elements: [VoiceElement] = [
                    .timeSignature(TimeSignature(numerator: 3, denominator: 4)),
                    .chord(Chord(duration: .quarter, notes: [Note(pitch: 71, tpc: 19, accidental: .mirroredFlat)])),
                    .chord(Chord(duration: .quarter, notes: [Note(pitch: 72, tpc: 14)])),
                    .chord(Chord(duration: .quarter, notes: [Note(pitch: 71, tpc: 19, accidental: .flatArrowDown)])),
                ]
                let staff = Staff(measures: [Measure(voices: [Voice(elements: elements)])])
                return Score(division: 480, parts: [Part(id: "p0", instrument: Instrument(id: "i"), staves: [staff])])
            }

            private func note(_ elementIndex: Int) -> NoteID {
                NoteID(
                    staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0, voiceIndex: 0,
                    elementIndex: elementIndex, noteIndexInChord: 0,
                )
            }

            private func setUp() throws -> (RecordingBackend, PlaybackEngine, Score) {
                let backend = RecordingBackend()
                let score = makeScore()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                try engine.prepare(score: score)
                return (backend, engine, score)
            }

            @Test("a microtonal audition bends before its key, and a plain one after it recentres")
            func auditionBendsAndRecentres() throws {
                let (backend, engine, score) = try setUp()
                engine.playPreview(noteID: note(1), in: score)
                engine.playPreview(noteID: note(2), in: score)
                engine.playPreview(noteID: note(3), in: score)
                let channel = try #require(backend.liveEvents.first.flatMap { event -> UInt8? in
                    if case let .bend(channel, _) = event { channel } else { nil }
                })
                #expect(backend.liveEvents == [
                    .bend(channel: channel, value: UInt16(MidiEvent.pitchBendValue(cents: -50))),
                    .noteOn(channel: channel, pitch: 71),
                    .bend(channel: channel, value: UInt16(MidiEvent.pitchBendCenter)),
                    .noteOn(channel: channel, pitch: 72),
                    .bend(channel: channel, value: UInt16(MidiEvent.pitchBendValue(cents: -150))),
                    .noteOn(channel: channel, pitch: 71),
                ])
            }

            @Test("a plain audition on an unbent channel sends no wheel at all")
            func plainAuditionSendsNoWheel() throws {
                let (backend, engine, score) = try setUp()
                engine.playPreview(noteID: note(2), in: score)
                #expect(backend.liveEvents.allSatisfy { if case .noteOn = $0 { true } else { false } })
            }

            /// A channel with no microtonal note carries no wheel event of its own, so the score would play a
            /// quarter tone out on it if the audition's bend were left standing.
            @Test("playback recentres the wheel an audition left bent")
            func playbackRecentres() throws {
                let (backend, engine, score) = try setUp()
                engine.playPreview(noteID: note(1), in: score)
                engine.play(in: score)
                #expect(backend.didPlay)
                guard case let .bend(_, value) = backend.liveEvents.last else {
                    Issue.record("no recentring bend: \(backend.liveEvents)")
                    return
                }
                #expect(value == UInt16(MidiEvent.pitchBendCenter))
            }
        }
    }
#endif
