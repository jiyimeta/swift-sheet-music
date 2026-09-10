@testable import SheetMusicCore
import Testing

@Suite("System lane property identity")
struct SystemLanePropertyIdentityTests {
    private typealias F = SystemLaneIdentityFixtures
    private typealias V = VoiceIdentityFixtures

    @Test(arguments: [false, true], 0 ..< 4)
    func propertyChangesKeepSlots(rehearsal: Bool, property: Int) throws {
        let mark: F.Mark = rehearsal ? .rehearsal : .staffText
        let editor = ScoreEditor(score: F.score([mark.value()]))
        let before = editor.score
        let initial = editor.idAllocator
        let target: ScoreTextID = rehearsal
            ? .rehearsalMark(measureIndex: 0)
            : .staffText(anchor: V.location(0), style: .staffText)
        let command: any EditCommand = switch property {
        case 0: SetElementColor(.text(target), color: ScoreColor(red: 255, green: 0, blue: 0))
        case 1: SetElementPlacement(.text(target), placement: .below)
        case 2: SetTextFont(target, patch: .init(face: .set("serif")))
        default: SetTextVisible(target, visible: false)
        }
        try editor.apply(command)
        #expect(editor.score != before)
        #expect(F.ids(editor.score) == F.ids(before))
        #expect(editor.idAllocator == initial)
        try F.expectCycle(editor, before: before)
    }

    @Test(arguments: 0 ..< 3)
    func partReanchoringKeepsSlots(_ operation: Int) throws {
        var literal = F.score([
            PositionedSystemElement(
                position: .start, element: .staffText(StaffText(text: "first")), originalStaff: V.staff,
            ),
            PositionedSystemElement(
                position: .start, element: .staffText(StaffText(text: "second")),
                originalStaff: StaffAddress(partIndex: 1, staffIndexInPart: 0),
            ),
        ])
        literal.parts = IdentifiedArray([literal.parts[0], Part(
            id: "P2", instrument: Instrument(id: "cello"),
            staves: [Staff(measures: [Measure(voices: [Voice(elements: [.rest(duration: .whole)])])])],
        )])
        let editor = ScoreEditor(score: literal)
        let before = editor.score
        let initial = editor.idAllocator
        let command: any EditCommand = switch operation {
        case 0: AddPart(plan: .init(instrumentID: "flute", staves: [.init(clefType: "G")]), at: 0)
        case 1: RemovePart(partIndex: 0)
        default: MovePart(from: 0, to: 1)
        }
        try editor.apply(command)
        #expect(F.ids(editor.score) == F.ids(before))
        let expectedParts = switch operation {
        case 0: [1, 2]
        case 1: [0, 0]
        default: [1, 0]
        }
        let actualParts = editor.score.systemMeasures[0].elements.map { $0.originalStaff?.partIndex }
        #expect(actualParts == expectedParts)
        if operation == 0 {
            // A new staff, its rest, then its part; no lane occupant is minted.
            #expect(editor.idAllocator == V.advanced(initial, by: 3))
            #expect(editor.score.parts[0].staves.eid(at: 0) == V.minted(initial, 1))
            #expect(V.elements(editor.score).eid(at: 0) == V.minted(initial, 2))
            #expect(editor.score.parts.eid(at: 0) == V.minted(initial, 3))
        } else {
            #expect(editor.idAllocator == initial)
        }
        try F.expectCycle(editor, before: before)
    }
}
