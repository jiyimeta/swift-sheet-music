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

            /// One quarter on a 1/4 downbeat in each of `voices`, each chord holding its notes in the order given.
            private func chordScore(_ voices: [[Note]]) -> Score {
                let measure = Measure(voices: voices.enumerated().map { index, notes in
                    let meter: [VoiceElement] = index == 0
                        ? [.timeSignature(TimeSignature(numerator: 1, denominator: 4))] : []
                    return Voice(elements: meter + [.chord(Chord(duration: .quarter, notes: ChordNotes(notes)))])
                })
                let staff = Staff(measures: [measure])
                return Score(division: 480, parts: [Part(id: "p0", instrument: Instrument(id: "i"), staves: [staff])])
            }

            /// Everything a tap on the downbeat sounds, the way a reader tap asks for it.
            private func downbeat(of score: Score) -> [NoteID] {
                score.onsetNoteIDs(of: .note(NoteID(
                    staff: StaffAddress(partIndex: 0, staffIndexInPart: 0), measureIndex: 0, voiceIndex: 0,
                    elementIndex: 1, noteIndexInChord: 0,
                )))
            }

            /// The wheel playback holds when the downbeat's last key strikes. One channel carries one wheel, so every
            /// key of the beat sounds under it (`MicrotonalPitchWheel`: the last strike's offset wins).
            private func playbackWheel(of score: Score) throws -> UInt16 {
                let track = try #require(MidiRenderer.render(score: score).tracks.first)
                var wheel = UInt16(MidiEvent.pitchBendCenter)
                var atLastStrike = wheel
                for event in track.events where event.tick == 0 {
                    switch event.event {
                    case let .pitchBend(_, value): wheel = UInt16(value)
                    case let .noteOn(_, _, velocity) where velocity > 0: atLastStrike = wheel
                    default: break
                    }
                }
                return atLastStrike
            }

            /// The wheel an audition struck its keys under: the last bend it sent before its first key, or the
            /// center when it sent none (the channel starts centered).
            private func auditionWheel(_ events: [RecordingBackend.LiveEvent]) -> UInt16 {
                var wheel = UInt16(MidiEvent.pitchBendCenter)
                for event in events {
                    switch event {
                    case let .bend(_, value): wheel = value
                    case .noteOn: return wheel
                    }
                }
                return wheel
            }

            /// A beat whose keys want different offsets: playback's one wheel takes the LAST key's, so the tap has to
            /// as well, or the chord the user taps is not the chord they then hear played.
            @Test(
                "an audition of a beat with mixed offsets bends to its last key's, as playback does",
                arguments: [
                    // A quarter-flat B under a plain D: the D strikes last and takes the wheel back to center.
                    [[Note(pitch: 71, tpc: 19, accidental: .mirroredFlat), Note(pitch: 74, tpc: 16)]],
                    // The same two keys the other way round: the quarter-flat strikes last.
                    [[Note(pitch: 74, tpc: 16), Note(pitch: 71, tpc: 19, accidental: .mirroredFlat)]],
                    // Across voices: voice 1's quarter-flat, then voice 2's plain C.
                    [[Note(pitch: 71, tpc: 19, accidental: .mirroredFlat)], [Note(pitch: 60, tpc: 14)]],
                    // Two different offsets in one chord: the three-quarter-flat strikes last.
                    [[
                        Note(pitch: 71, tpc: 19, accidental: .mirroredFlat),
                        Note(pitch: 76, tpc: 18, accidental: .flatArrowDown),
                    ]],
                ],
            )
            func mixedOffsetsFollowPlayback(voices: [[Note]]) throws {
                let backend = RecordingBackend()
                let score = chordScore(voices)
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                try engine.prepare(score: score)
                let noteIDs = downbeat(of: score)
                #expect(noteIDs.count == voices.joined().count)
                engine.playPreview(noteIDs: noteIDs, in: score)
                let auditioned = auditionWheel(backend.liveEvents)
                let played = try playbackWheel(of: score)
                #expect(auditioned == played)
                let lastOffset = voices.joined().last?.accidental?.centOffset ?? 0
                #expect(auditioned == UInt16(MidiEvent.pitchBendValue(cents: lastOffset)))
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
