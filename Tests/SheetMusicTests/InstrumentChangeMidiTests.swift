import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

@Suite("InstrumentChange MIDI")
struct InstrumentChangeMidiTests {
    static func fixtureScore() throws -> Score {
        let url = try #require(
            Bundle.module.url(
                forResource: "instrument-change", withExtension: "mscx",
            ),
        )
        return try MSCXParser.parse(Data(contentsOf: url))
    }

    @Test("one assignment per change instance, not per distinct instrument")
    func assignmentPerInstance() throws {
        let assignments = try MidiRenderer.assignChannels(score: Self.fixtureScore())
        #expect(assignments.count == 1)
        #expect(assignments[0].count == 2)
        #expect(assignments[0].map(\.instrumentOrdinal) == [0, 1])
        // The tick-0 piano has no <midiChannel>, so it takes channel 0.
        #expect(assignments[0][0].channel == 0)
        // The accordion declares <midiChannel>5</midiChannel>.
        #expect(assignments[0][1].channel == 5)
        #expect(assignments[0][1].flavour.program == 21)
    }

    @Test("channel identity is the (port, channel) pair")
    func portIsPartOfIdentity() {
        let a = MidiChannelKey(port: 0, channel: 3)
        let b = MidiChannelKey(port: 1, channel: 3)
        #expect(a != b)
        #expect(Set([a, b]).count == 2)
    }

    @Test("a declared midiPort rides on the assignment, not the part")
    func declaredPortIsHonoured() {
        var accordion = Instrument(
            id: "accordion",
            channels: [InstrumentChannel(program: 21, midiChannel: 3, midiPort: 1)],
        )
        accordion.longName = "Accordion"
        let bar = Measure(voices: [Voice(elements: [])])
        let score = Score(
            division: 480,
            parts: [Part(
                id: "P1",
                instrument: Instrument(id: "piano", channels: [InstrumentChannel(midiChannel: 3)]),
                staves: [Staff(measures: [bar, bar])],
            )],
            systemMeasures: [
                SystemMeasure(),
                SystemMeasure(elements: [PositionedSystemElement(
                    position: MeasurePosition(offset: Fraction(numerator: 0, denominator: 1)),
                    element: .instrumentChange(
                        InstrumentChange(text: "to Accordion", instrument: accordion),
                    ),
                    originalStaff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
                )]),
            ],
        )
        let assignments = MidiRenderer.assignChannels(score: score)
        // Same wire channel number, different port — two distinct keys.
        #expect(assignments[0][0].key == MidiChannelKey(port: 0, channel: 3))
        #expect(assignments[0][1].key == MidiChannelKey(port: 1, channel: 3))
    }

    @Test("both instruments get a full header block at tick 0")
    func headersForEveryInstrumentAtTickZero() throws {
        let midi = try MidiRenderer.render(score: Self.fixtureScore())
        let tickZeroPrograms = midi.tracks[0].events
            .filter { $0.tick == 0 }
            .compactMap { event -> (Int, Int)? in
                guard case let .programChange(channel, program) = event.event
                else { return nil }
                return (channel, program)
            }
        #expect(tickZeroPrograms.contains { $0 == (0, 0) }) // piano
        #expect(tickZeroPrograms.contains { $0 == (5, 21) }) // accordion
    }

    @Test("no program change is emitted after tick 0")
    func noMidStreamProgramChange() throws {
        let midi = try MidiRenderer.render(score: Self.fixtureScore())
        let late = midi.tracks.flatMap(\.events).filter { event in
            guard case .programChange = event.event else { return false }
            return event.tick > 0
        }
        #expect(late.isEmpty)
    }
}
