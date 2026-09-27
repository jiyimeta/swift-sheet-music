@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

@Suite("Dangling tuplet selection expansion")
struct DanglingTupletSelectionExpansionTests {
    private static let staffAddress = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    @Test("a tuplet with a dangling last endpoint expands only to its own ID")
    func danglingLastEndpointIsNotExpanded() {
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
        let score = Score(division: 480, parts: [
            Part(id: "1", trackName: "Flute", instrument: Instrument(id: "flute"), staves: [staff]),
        ])
        let id = ScoreItemID.tuplet(TupletID(
            staff: Self.staffAddress,
            measureIndex: 0,
            voiceIndex: 0,
            startElementIndex: 0,
        ))

        // Public entry point: `SelectionExpansion.expand(_:in:)`.
        #expect(SelectionExpansion.expand(id, in: score) == [id])
    }

    private static func quarter(_ pitch: Int, _ tpc: Int) -> VoiceElement {
        .chord(Chord(duration: .quarter, notes: [Note(pitch: pitch, tpc: tpc)]))
    }
}
