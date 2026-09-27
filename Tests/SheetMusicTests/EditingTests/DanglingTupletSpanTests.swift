@testable import SheetMusicCore
import Testing

@Suite("Dangling tuplet spans")
struct DanglingTupletSpanTests {
    private static let staff = StaffAddress(partIndex: 0, staffIndexInPart: 0)

    private static func slot(_ element: Int) -> VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: 0, voiceIndex: 0, elementIndex: element)
    }

    @Test("RemoveTuplet refuses a target covered only by a dangling-first span")
    func removeTupletIgnoresDanglingFirstEndpoint() {
        var score = Self.scoreWithDanglingFirstTuplet()

        // Public entry point: the `RemoveTuplet` intent's `apply(to:)`.
        let error = #expect(throws: SheetMusicError.self) {
            _ = try RemoveTuplet(at: Self.slot(1)).apply(to: &score)
        }

        guard case let .invalidEdit(refusal)? = error else {
            Issue.record("expected an invalidEdit refusal")
            return
        }
        #expect(refusal.reason == .wrongElementKind(at: Self.slot(1), expected: .tuplet))
    }

    @Test("SetChordDuration treats a dangling-first span as no tuplet")
    func durationChangeIgnoresDanglingFirstEndpoint() throws {
        var score = Self.scoreWithDanglingFirstTuplet()

        // Public entry point: `SetChordDuration.apply(to:)`; this runs both
        // `TupletDurationChange` and `DurationChangeAlgorithm` on the path.
        _ = try SetChordDuration(at: Self.slot(0), duration: .half).apply(to: &score)

        let elements = score.parts[0].staves[0].measures[0].voices[0].elements
        #expect(elements.count == 3)
        guard case let .chord(chord) = elements[0] else {
            Issue.record("expected the changed chord at element 0")
            return
        }
        #expect(chord.duration == .half)
        #expect(chord.notes.first?.pitch == 60)
        guard case let .chord(following) = elements[1] else {
            Issue.record("expected the following chord at element 1")
            return
        }
        #expect(following.notes.first?.pitch == 64)
    }

    private static func scoreWithDanglingFirstTuplet() -> Score {
        let dangling = EID(first: 0, second: 99)
        let third = EID(first: 0, second: 3)
        let elements = IdentifiedArray([
            (EID(first: 0, second: 1), quarter(60, 14)),
            (EID(first: 0, second: 2), quarter(62, 16)),
            (third, quarter(64, 18)),
            (EID(first: 0, second: 4), quarter(65, 19)),
        ])
        let voice = Voice(
            elements: elements,
            tuplets: [Tuplet(normalNotes: 2, actualNotes: 3, first: dangling, last: third)],
        )
        let staff = Staff(defaultClefType: "G", measures: [Measure(voices: [voice])])
        return Score(division: 480, parts: [
            Part(id: "1", trackName: "Flute", instrument: Instrument(id: "flute"), staves: [staff]),
        ])
    }

    private static func quarter(_ pitch: Int, _ tpc: Int) -> VoiceElement {
        .chord(Chord(duration: .quarter, notes: [Note(pitch: pitch, tpc: tpc)]))
    }
}
