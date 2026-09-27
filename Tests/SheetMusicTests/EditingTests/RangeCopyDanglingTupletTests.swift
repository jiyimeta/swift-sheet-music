@testable import SheetMusicCore
import Testing

@Suite("RangeCopy dangling tuplet")
struct RangeCopyDanglingTupletTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ element: Int) -> VoiceElementID {
        VoiceElementID(staff: flute, measureIndex: 0, voiceIndex: 0, elementIndex: element)
    }

    @Test("a dangling tuplet endpoint does not trap range duplication")
    func danglingLastEndpointIsSkipped() throws {
        let first = EID(first: 0, second: 1)
        let dangling = EID(first: 0, second: 99)
        let elements = IdentifiedArray([
            (first, Self.quarter(60, 14)),
            (EID(first: 0, second: 2), Self.quarter(62, 16)),
            (EID(first: 0, second: 3), Self.quarter(64, 18)),
            (EID(first: 0, second: 4), Self.quarter(65, 19)),
        ])
        let voice = Voice(
            elements: elements,
            tuplets: [Tuplet(normalNotes: 2, actualNotes: 3, first: first, last: dangling)],
        )
        let staff = Staff(defaultClefType: "G", measures: [Measure(voices: [voice])])
        var score = Score(division: 480, parts: [
            Part(id: "1", trackName: "Flute", instrument: Instrument(id: "flute"), staves: [staff]),
        ])

        _ = try DuplicateRange(over: VoiceElementRange(start: Self.slot(0), end: Self.slot(1)))
            .apply(to: &score)

        let copied = score.parts[0].staves[0].measures[0].voices[0].elements
        #expect(copied.values == [
            Self.quarter(60, 14), Self.quarter(62, 16), Self.quarter(60, 14), Self.quarter(62, 16),
        ])
    }

    private static func quarter(_ pitch: Int, _ tpc: Int) -> VoiceElement {
        .chord(Chord(duration: .quarter, notes: [Note(pitch: pitch, tpc: tpc)]))
    }
}
