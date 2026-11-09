#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAudio
    @testable import SheetMusicAudioApple
    @testable import SheetMusicAudioCore
    @testable import SheetMusicCore
    import Testing

    /// Mute and solo choose what the playback is heard with; a preview is the user asking to hear one note, so a part
    /// muted or shut out by a solo still answers a tap or a held key (`MixerChannel.previewGain`) — and is muted again
    /// before the transport's first block.
    extension AudioEngineSerial {
        @Suite("PlaybackEngine preview under mute and solo")
        @MainActor
        struct PlaybackEnginePreviewMixTests {
            private struct NullResolver: SoundfontResolver {
                func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
                    nil
                }

                var defaultGMSoundfontURL: URL? {
                    nil
                }
            }

            private static let first = MixerChannel.Kind.instrument(partIndex: 0, ordinal: 0)
            private static let second = MixerChannel.Kind.instrument(partIndex: 1, ordinal: 0)
            /// 0.5 on the slider: 63.5, rounded.
            private static let halfCC7: UInt8 = 64

            /// Two parts of four quarters each.
            private func makeScore() -> Score {
                func part(_ id: String, program: Int) -> Part {
                    let quarter = Chord(duration: .quarter, notes: [Note(pitch: 60, tpc: 14)])
                    let measure = Measure(voices: [Voice(elements: [
                        .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                        .chord(quarter), .chord(quarter), .chord(quarter), .chord(quarter),
                    ])])
                    return Part(
                        id: id,
                        instrument: Instrument(id: "i-\(id)", channels: [InstrumentChannel(program: program)]),
                        staves: [Staff(measures: [measure, measure])],
                    )
                }
                return Score(division: 480, parts: [part("p0", program: 0), part("p1", program: 40)])
            }

            /// The first part's first note.
            private let firstNote = NoteID(
                staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                measureIndex: 0, voiceIndex: 0, elementIndex: 1, noteIndexInChord: 0,
            )

            /// The engine with the first part's slider at 0.5, and that part's MIDI channel.
            private func setUp() throws -> (RecordingBackend, PlaybackEngine, Score, UInt8) {
                let backend = RecordingBackend()
                let score = makeScore()
                let engine = PlaybackEngine(soundfontResolver: NullResolver(), backend: backend)
                try engine.prepare(score: score)
                engine.setVolume(forChannel: Self.first, to: 0.5)
                let channel = try #require(engine.midiChannel(forChannel: Self.first))
                return (backend, engine, score, channel)
            }

            @Test("a muted part's tapped note sounds at its slider")
            func mutedPartTapSounds() throws {
                let (backend, engine, score, channel) = try setUp()
                engine.setMuted(forChannel: Self.first, to: true)
                #expect(backend.currentVolumes[channel] == 0)

                engine.playPreview(noteID: firstNote, in: score)

                #expect(backend.liveEvents.contains(.noteOn(channel: channel, pitch: 60)))
                #expect(backend.currentVolumes[channel] == Self.halfCC7)
            }

            @Test("a part shut out by another's solo sounds its tapped note")
            func soloShutPartTapSounds() throws {
                let (backend, engine, score, channel) = try setUp()
                engine.setSoloed(forChannel: Self.second, to: true)
                #expect(backend.currentVolumes[channel] == 0)

                engine.playPreview(noteID: firstNote, in: score)

                #expect(backend.currentVolumes[channel] == Self.halfCC7)
            }

            @Test("a held key on a muted part sounds at its slider")
            func mutedPartHeldKeySounds() throws {
                let (backend, engine, _, channel) = try setUp()
                engine.setMuted(forChannel: Self.first, to: true)

                engine.previewNoteOn(pitch: 60, onStaff: 0, atTick: 0)

                #expect(backend.liveEvents.contains(.noteOn(channel: channel, pitch: 60)))
                #expect(backend.currentVolumes[channel] == Self.halfCC7)
            }

            @Test("play mutes the part again before the transport starts", arguments: [false, true])
            func playMutesAgainBeforeStarting(countIn: Bool) throws {
                let (backend, engine, score, channel) = try setUp()
                engine.setMuted(forChannel: Self.first, to: true)
                engine.playPreview(noteID: firstNote, in: score)

                engine.play(in: score, countIn: countIn)

                #expect(backend.playCallCount == 1)
                #expect(backend.volumesAtLastPlay[channel] == 0)
                #expect(backend.currentVolumes[channel] == 0)
            }

            /// A resumed transport is not reset before its first block, so the lifted level would carry into it.
            @Test("resuming from a pause mutes the part again before the transport starts")
            func resumeMutesAgainBeforeStarting() throws {
                let (backend, engine, score, channel) = try setUp()
                engine.setMuted(forChannel: Self.first, to: true)
                engine.play(in: score)
                engine.pause()
                engine.previewNoteOn(pitch: 60, onStaff: 0, atTick: 0)
                engine.previewNoteOff(pitch: 60)
                #expect(backend.currentVolumes[channel] == Self.halfCC7)

                engine.play(in: score)

                #expect(backend.playCallCount == 2)
                #expect(backend.volumesAtLastPlay[channel] == 0)
            }

            /// The preview strikes the channel the music plays on: opening it would bring the part back under it.
            @Test("a preview while the score plays leaves the muted part muted")
            func previewWhilePlayingKeepsMute() throws {
                let (backend, engine, score, channel) = try setUp()
                engine.setMuted(forChannel: Self.first, to: true)
                engine.play(in: score)

                engine.playPreview(noteID: firstNote, in: score)

                #expect(backend.currentVolumes[channel] == 0)
            }

            @Test("an audible part's tapped note keeps its slider")
            func audiblePartKeepsItsLevel() throws {
                let (backend, engine, score, channel) = try setUp()

                engine.playPreview(noteID: firstNote, in: score)

                #expect(backend.currentVolumes[channel] == Self.halfCC7)
            }
        }
    }
#endif
