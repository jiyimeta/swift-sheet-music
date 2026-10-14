#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    #if canImport(SwiftySynth)
        @testable import SheetMusicAudioSwiftySynth
        import SheetMusicMIDI
        import Testing

        /// Which presets a sequence sounds — the instruments the backend reads in before playback reaches them.
        struct SwiftySynthPrefetchTests {
            private static func file(_ tracks: [[TimedMidiEvent]]) -> MidiFile {
                MidiFile(division: 480, tracks: tracks.map { MidiTrack(events: $0) })
            }

            private static func at(_ tick: Int, _ event: MidiEvent) -> TimedMidiEvent {
                TimedMidiEvent(tick: tick, event: event)
            }

            @Test func `a channel set to its program before its first note never sounds the initial piano`() {
                let midi = Self.file([[
                    Self.at(0, .programChange(channel: 0, program: 40)),
                    Self.at(0, .noteOn(channel: 0, pitch: 60, velocity: 90)),
                ]])
                #expect(SwiftySynthBackend.playedPresets(in: midi) == [PlayedPreset(channel: 0, bank: 0, program: 40)])
            }

            @Test func `the percussion channel resolves in the drum bank`() {
                let midi = Self.file([[Self.at(0, .noteOn(channel: 9, pitch: 36, velocity: 100))]])
                #expect(SwiftySynthBackend.playedPresets(in: midi) == [PlayedPreset(channel: 9, bank: 0, program: 0)])
                #expect(PlayedPreset(channel: 9, bank: 0, program: 0).bank == 128)
            }

            @Test func `a bank select carries into the presets the channel plays`() {
                let midi = Self.file([[
                    Self.at(0, .controlChange(channel: 1, controller: 0, value: 8)),
                    Self.at(0, .programChange(channel: 1, program: 5)),
                    Self.at(10, .noteOn(channel: 1, pitch: 64, velocity: 80)),
                ]])
                #expect(SwiftySynthBackend.playedPresets(in: midi) == [PlayedPreset(channel: 1, bank: 8, program: 5)])
            }

            @Test func `a program change at a note's tick on another track counts before the note`() {
                let midi = Self.file([
                    [Self.at(0, .noteOn(channel: 2, pitch: 67, velocity: 70))],
                    [Self.at(0, .programChange(channel: 2, program: 73))],
                ])
                #expect(SwiftySynthBackend.playedPresets(in: midi) == [PlayedPreset(channel: 2, bank: 0, program: 73)])
            }

            @Test func `every program a channel plays in turn is read in, and only those`() {
                let midi = Self.file([[
                    Self.at(0, .programChange(channel: 0, program: 0)),
                    Self.at(0, .noteOn(channel: 0, pitch: 60, velocity: 90)),
                    Self.at(480, .programChange(channel: 0, program: 48)),
                    Self.at(960, .programChange(channel: 0, program: 56)),
                    Self.at(960, .noteOn(channel: 0, pitch: 62, velocity: 90)),
                    // A velocity-0 note-on is a note-off: it sounds nothing.
                    Self.at(1440, .programChange(channel: 0, program: 70)),
                    Self.at(1440, .noteOn(channel: 0, pitch: 62, velocity: 0)),
                ]])
                #expect(SwiftySynthBackend.playedPresets(in: midi) == [
                    PlayedPreset(channel: 0, bank: 0, program: 0),
                    PlayedPreset(channel: 0, bank: 0, program: 56),
                ])
            }
        }
    #endif
#endif
