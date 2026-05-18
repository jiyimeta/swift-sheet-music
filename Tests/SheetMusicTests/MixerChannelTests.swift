#if !os(Android)
    import Foundation
    @testable import SheetMusicAudio
    @testable import SheetMusicCore
    import Testing

    @Suite("MixerChannel program for drumset")
    @MainActor
    struct MixerChannelTests {
        /// A drum-kit part has its MIDI program slot ignored by GM
        /// playback (drums are routed to channel 10 and use note pitch
        /// as the kit-piece selector). Showing a GM program name in the
        /// picker would be misleading — `program == nil` hides the
        /// picker in the mixer UI.
        @Test("Drumset staff has nil program in mixer")
        func drumsetStaffHasNilProgram() throws {
            let part = Part(
                id: "drums",
                instrument: Instrument(
                    id: "drumset",
                    channels: [InstrumentChannel(program: 0)],
                    useDrumset: true,
                ),
                staves: [Staff(measures: [Measure(voices: [])])],
            )
            let score = Score(division: 480, parts: [part])
            let engine = PlaybackEngine(soundfontResolver: NullResolver())
            try engine.prepare(score: score)
            let drumChannel = try #require(
                engine.mixerChannels.first { $0.id == .staff(0) },
            )
            #expect(drumChannel.program == nil)
        }

        /// Non-drum parts keep their GM program from the InstrumentChannel
        /// so the picker can display the matching GM patch name.
        @Test("Pitched staff carries its GM program through to the mixer")
        func pitchedStaffCarriesProgram() throws {
            let part = Part(
                id: "lead",
                instrument: Instrument(
                    id: "soprano",
                    channels: [InstrumentChannel(program: 80)],
                ),
                staves: [Staff(measures: [Measure(voices: [])])],
            )
            let score = Score(division: 480, parts: [part])
            let engine = PlaybackEngine(soundfontResolver: NullResolver())
            try engine.prepare(score: score)
            let strip = try #require(
                engine.mixerChannels.first { $0.id == .staff(0) },
            )
            #expect(strip.program == 80)
        }
    }

    private struct NullResolver: SoundfontResolver {
        func soundfontURL(forBank bank: UInt8, program: UInt8, isDrums: Bool) -> URL? {
            nil
        }

        var defaultGMSoundfontURL: URL? {
            nil
        }
    }
#endif
