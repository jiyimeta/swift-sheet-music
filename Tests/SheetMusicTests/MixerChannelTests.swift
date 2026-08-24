#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    @testable import SheetMusicAudio
    @testable import SheetMusicAudioCore
    @testable import SheetMusicCore
    import Testing

    extension AudioEngineSerial {
        @Suite("MixerChannel program for drumset")
        @MainActor
        struct MixerChannelTests {
            /// A drum strip's program is the KIT — a bank-128 preset, not a
            /// melodic patch — and it is selectable, so it is reported.
            /// This test used to assert `nil`, on the reasoning that drums
            /// ignore their program slot. They do not: a program change on
            /// the GM drum channel chooses the kit, and hiding the value
            /// left both the picker and the score's OWN authored kit with
            /// nothing to act on. `isDrums` is what tells a host to offer
            /// the drum catalog instead of the melodic one; `nil` now means
            /// only the metronome.
            @Test("Drumset staff reports its kit program and flags itself as drums")
            func drumsetStaffReportsKitProgram() throws {
                let part = Part(
                    id: "drums",
                    instrument: Instrument(
                        id: "drumset",
                        channels: [InstrumentChannel(program: 16)],
                        useDrumset: true,
                    ),
                    staves: [Staff(measures: [Measure(voices: [])])],
                )
                let score = Score(division: 480, parts: [part])
                let engine = PlaybackEngine(soundfontResolver: NullResolver())
                try engine.prepare(score: score)
                let drumChannel = try #require(
                    engine.mixerChannels.first { $0.id == .instrument(partIndex: 0, ordinal: 0) },
                )
                #expect(drumChannel.program == 16)
                #expect(drumChannel.isDrums)
                let metronome = try #require(engine.mixerChannels.first { $0.id == .metronome })
                #expect(metronome.program == nil)
                #expect(!metronome.isDrums)
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
                    engine.mixerChannels.first { $0.id == .instrument(partIndex: 0, ordinal: 0) },
                )
                #expect(strip.program == 80)
            }
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
