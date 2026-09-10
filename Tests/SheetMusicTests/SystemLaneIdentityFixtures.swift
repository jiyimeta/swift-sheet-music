@testable import SheetMusicCore
import Testing

enum SystemLaneIdentityFixtures {
    static func score(_ elements: [PositionedSystemElement], measures: Int = 1) -> Score {
        var score = VoiceIdentityFixtures.score((0 ..< measures).map { _ in
            [Voice(elements: [.rest(duration: .whole)])]
        })
        score.systemMeasures.updateValue(at: 0) { $0 = SystemMeasure(elements: elements) }
        return score
    }

    static func ids(_ score: Score, measure: Int = 0) -> [EID] {
        let elements = score.systemMeasures[measure].elements
        return elements.indices.map { elements.eid(at: $0) }
    }

    static func expectCycle(
        _ editor: ScoreEditor, before: Score, sourceLocation: SourceLocation = #_sourceLocation,
    ) throws {
        let after = editor.score
        let allocator = editor.idAllocator
        try editor.undo()
        VoiceIdentityFixtures.expectSameScore(editor.score, before, sourceLocation: sourceLocation)
        try editor.redo()
        VoiceIdentityFixtures.expectSameScore(editor.score, after, sourceLocation: sourceLocation)
        try editor.undo()
        VoiceIdentityFixtures.expectSameScore(editor.score, before, sourceLocation: sourceLocation)
        #expect(editor.idAllocator == allocator, sourceLocation: sourceLocation)
    }

    enum Mark: CaseIterable, Sendable {
        case tempo, staffText, systemText, rehearsal

        func value(changed: Bool = false) -> PositionedSystemElement {
            let element: SystemElement = switch self {
            case .tempo: .tempo(Tempo(beatsPerSecond: changed ? 3 : 2))
            case .staffText: .staffText(StaffText(text: changed ? "new" : "old"))
            case .systemText: .staffText(StaffText(text: changed ? "new" : "old", isSystemText: true))
            case .rehearsal: .rehearsalMark(RehearsalMark(text: changed ? "new" : "old"))
            }
            return PositionedSystemElement(
                position: .start, element: element,
                originalStaff: self == .staffText ? VoiceIdentityFixtures.staff : nil,
            )
        }

        func command(removing: Bool = false) -> any EditCommand {
            let anchor = VoiceIdentityFixtures.location(0)
            switch self {
            case .tempo:
                return SetTempo(anchor: anchor, marking: removing ? nil : .init(beatsPerSecond: 3))
            case .staffText, .systemText:
                return SetStaffText(anchor: anchor, text: removing ? nil : "new", isSystemText: self == .systemText)
            case .rehearsal:
                if removing { return RemoveRehearsalMark(measureIndex: 0) }
                return SetRehearsalMark(measureIndex: 0, text: "new")
            }
        }
    }
}
