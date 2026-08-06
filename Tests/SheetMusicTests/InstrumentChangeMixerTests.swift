#if !os(Android)
    import Foundation
    @testable import SheetMusicAudioCore
    @testable import SheetMusicCore
    @testable import SheetMusicMIDI
    @testable import SheetMusicMSCX
    import Testing

    @Suite("InstrumentChange mixer")
    struct InstrumentChangeMixerTests {
        static func fixtureScore() throws -> Score {
            let url = try #require(
                Bundle.module.url(
                    forResource: "instrument-change", withExtension: "mscx",
                ),
            )
            return try MSCXParser.parse(Data(contentsOf: url))
        }

        @Test("one strip per (part × distinct instrument)")
        func stripPerInstrument() throws {
            let plan = try LiveChannelPlan.build(score: Self.fixtureScore())
            #expect(plan.strips.map { ($0.partIndex, $0.ordinal) }.count == 2)
            #expect(plan.strips[0].instrument.id == "piano")
            #expect(plan.strips[1].instrument.id == "accordion")
        }

        @Test("a grand-staff part shows ONE strip, not one per staff")
        func grandStaffCollapses() {
            let bar = Measure(voices: [Voice(elements: [])])
            let score = Score(
                division: 480,
                parts: [Part(
                    id: "P1",
                    instrument: Instrument(id: "piano", channels: [InstrumentChannel()]),
                    staves: [Staff(measures: [bar]), Staff(measures: [bar])],
                )],
                systemMeasures: [SystemMeasure()],
            )
            // Today `staffChannels` hands every staff of a part the same
            // channel, so a grand staff shows two strips driving one
            // channel. Per-(part × instrument) strips remove the duplicate.
            #expect(LiveChannelPlan.build(score: score).strips.count == 1)
        }

        @Test("Kind is Hashable and distinguishes ordinals")
        func kindIdentity() {
            let a = MixerChannel.Kind.instrument(partIndex: 0, ordinal: 0)
            let b = MixerChannel.Kind.instrument(partIndex: 0, ordinal: 1)
            let c = MixerChannel.Kind.instrument(partIndex: 1, ordinal: 0)
            #expect(Set([a, b, c, .metronome]).count == 4)
        }

        @Test("program re-assertion covers every deduped instrument channel")
        func managedChannelsCoverSecondaries() throws {
            let plan = try LiveChannelPlan.build(score: Self.fixtureScore())
            // With all programs living at tick 0, re-asserting only the
            // primary staff channel would leave the accordion playing
            // program 0 piano.
            #expect(plan.managedChannels.count == 2)
            #expect(
                plan.managedChannels
                    == Set(plan.strips.map(\.liveChannel)),
            )
        }
    }
#endif
