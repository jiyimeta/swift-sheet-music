@testable import SheetMusicCore
import Testing

@Suite("ScoreItemID.mappingStaves and SystemLaneSlot.anchor")
struct ScoreItemIDStaffMappingTests {
    private static let from = StaffAddress(partIndex: 1, staffIndexInPart: 1)
    private static let to = StaffAddress(partIndex: 0, staffIndexInPart: 1)

    private static func slot(_ staff: StaffAddress, element: Int = 2) -> VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: 3, voiceIndex: 1, elementIndex: element)
    }

    private static func note(_ staff: StaffAddress, element: Int = 2) -> NoteID {
        NoteID(staff: staff, measureIndex: 3, voiceIndex: 1, elementIndex: element, noteIndexInChord: 1)
    }

    /// Part 1 becomes part 0, staff for staff — so `from` becomes `to`, and part 1's name part 0's.
    private func moved(_ item: ScoreItemID) -> ScoreItemID? {
        item.mappingStaves { staff in
            staff.partIndex == 1 ? StaffAddress(partIndex: 0, staffIndexInPart: staff.staffIndexInPart) : staff
        }
    }

    @Test("every staff an identity names is mapped, and nothing else about it")
    func everyStaffIsMapped() {
        let pairs: [(ScoreItemID, ScoreItemID)] = [
            (.note(Self.note(Self.from)), .note(Self.note(Self.to))),
            (
                .text(.staffText(anchor: Self.slot(Self.from), style: .systemText)),
                .text(.staffText(anchor: Self.slot(Self.to), style: .systemText)),
            ),
            (
                .text(.lyric(anchor: Self.slot(Self.from), verse: 2)),
                .text(.lyric(anchor: Self.slot(Self.to), verse: 2)),
            ),
            (.element(.tempo(anchor: Self.slot(Self.from))), .element(.tempo(anchor: Self.slot(Self.to)))),
            (.element(.dynamic(anchor: Self.slot(Self.from))), .element(.dynamic(anchor: Self.slot(Self.to)))),
            (
                .element(.ornament(anchor: Self.slot(Self.from), kind: .upPrall)),
                .element(.ornament(anchor: Self.slot(Self.to), kind: .upPrall)),
            ),
            (
                .element(.keySignature(measureIndex: 3, staff: Self.from)),
                .element(.keySignature(measureIndex: 3, staff: Self.to)),
            ),
            (
                .element(.tie(start: Self.note(Self.from), end: Self.note(Self.from, element: 3))),
                .element(.tie(start: Self.note(Self.to), end: Self.note(Self.to, element: 3))),
            ),
            (.element(.partName(partIndex: 1, form: .long)), .element(.partName(partIndex: 0, form: .long))),
            (.clef(.staffDefault(Self.from)), .clef(.staffDefault(Self.to))),
        ]
        for (item, expected) in pairs {
            #expect(moved(item) == expected)
        }
    }

    @Test("a rehearsal mark and a barline name no staff of their own and pass through")
    func barAddressedIdentitiesPassThrough() {
        let mark = ScoreItemID.text(.rehearsalMark(measureIndex: 3))
        let barLine = ScoreItemID.element(.barLine(measureIndex: 3, role: .trailing))
        #expect(mark.mappingStaves { _ in nil } == mark)
        #expect(barLine.mappingStaves { _ in nil } == barLine)
    }

    @Test("an identity on a staff that is gone maps to nothing")
    func aGoneStaffIsNil() {
        #expect(ScoreItemID.note(Self.note(Self.from)).mappingStaves { _ in nil } == nil)
        let tie = ScoreItemID.element(.tie(start: Self.note(Self.to), end: Self.note(Self.from)))
        #expect(tie.mappingStaves { $0 == Self.from ? nil : $0 } == nil, "either end gone is the tie gone")
    }

    /// Two halves over four quarters: beat 2 is the lower staff's, beat 1 the top's.
    @Test("a score-wide mark's anchor is the beat's first chord in score order")
    func laneAnchorIsTheFirstStaffStartingTheBeat() {
        let halves = Staff(measures: [Measure(voices: [Voice(elements: [
            .chord(Chord(duration: .half, notes: [Note(pitch: 72, tpc: 14)])),
            .chord(Chord(duration: .half, notes: [Note(pitch: 74, tpc: 16)])),
        ])])])
        let quarters = Staff(measures: [Measure(voices: [Voice(elements: (0 ..< 4).map { index in
            .chord(Chord(duration: .quarter, notes: [Note(pitch: 60 + index, tpc: 14)]))
        })])])
        let score = Score(division: 480, parts: [
            Part(id: "P1", instrument: Instrument(id: "flute"), staves: [halves]),
            Part(id: "P2", instrument: Instrument(id: "piano"), staves: [quarters]),
        ])
        let top = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let lower = StaffAddress(partIndex: 1, staffIndexInPart: 0)
        #expect(SystemLaneSlot.anchor(at: .start, measureIndex: 0, in: score)
            == VoiceElementID(staff: top, measureIndex: 0, voiceIndex: 0, elementIndex: 0))
        #expect(SystemLaneSlot.anchor(at: MeasurePosition(numerator: 1, denominator: 4), measureIndex: 0, in: score)
            == VoiceElementID(staff: lower, measureIndex: 0, voiceIndex: 0, elementIndex: 1))
        #expect(
            SystemLaneSlot.anchor(at: MeasurePosition(numerator: 1, denominator: 8), measureIndex: 0, in: score)
                == nil,
            "control: a beat no staff starts",
        )
    }
}
