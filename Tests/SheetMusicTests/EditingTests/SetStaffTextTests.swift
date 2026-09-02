@testable import SheetMusicCore
import Testing

@Suite("SetStaffText")
struct SetStaffTextTests {
    private static let flute = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private static let cello = StaffAddress(partIndex: 1, staffIndexInPart: 0)

    private static func slot(_ staff: StaffAddress, _ measure: Int, _ element: Int) -> VoiceElementID {
        VoiceElementID(staff: staff, measureIndex: measure, voiceIndex: 0, elementIndex: element)
    }

    private static func texts(_ score: Score, _ measure: Int) -> [(String, Bool, StaffAddress?)] {
        guard score.systemMeasures.indices.contains(measure) else { return [] }
        return score.systemMeasures[measure].elements.compactMap { positioned in
            if case let .staffText(text) = positioned.element {
                (text.text, text.isSystemText, positioned.originalStaff)
            } else { nil }
        }
    }

    @Test("staff text is written on the anchor's staff, trimmed, at the anchor's beat")
    func writesStaffText() throws {
        var score = EditingFixtures.parityFixture()
        _ = try SetStaffText(anchor: Self.slot(Self.flute, 0, 2), text: "  pizz. ", isSystemText: false)
            .apply(to: &score)
        #expect(Self.texts(score, 0).map(\.0) == ["pizz."])
        #expect(Self.texts(score, 0).first?.1 == false)
        #expect(Self.texts(score, 0).first?.2 == Self.flute)
        #expect(score.systemMeasures[0].elements.first?.position == MeasurePosition(numerator: 1, denominator: 4))
        #expect(SetStaffText.current(at: Self.slot(Self.flute, 0, 2), isSystemText: false, in: score) == "pizz.")
    }

    @Test("system text carries no staff, and does not collide with staff text at the same beat")
    func systemTextIsSeparate() throws {
        var score = EditingFixtures.parityFixture()
        _ = try SetStaffText(anchor: Self.slot(Self.flute, 0, 1), text: "pizz.", isSystemText: false).apply(to: &score)
        _ = try SetStaffText(anchor: Self.slot(Self.flute, 0, 1), text: "rit.", isSystemText: true).apply(to: &score)
        #expect(Self.texts(score, 0).map(\.0) == ["pizz.", "rit."])
        #expect(Self.texts(score, 0).last?.2 == nil)
        #expect(SetStaffText.current(at: Self.slot(Self.flute, 0, 1), isSystemText: true, in: score) == "rit.")
        #expect(SetStaffText.current(at: Self.slot(Self.flute, 0, 1), isSystemText: false, in: score) == "pizz.")
    }

    @Test("a second staff's text at the same beat is its own")
    func perStaff() throws {
        var score = EditingFixtures.parityFixture()
        _ = try SetStaffText(anchor: Self.slot(Self.flute, 1, 0), text: "pizz.", isSystemText: false).apply(to: &score)
        _ = try SetStaffText(anchor: Self.slot(Self.cello, 1, 0), text: "arco", isSystemText: false).apply(to: &score)
        _ = try SetStaffText(anchor: Self.slot(Self.cello, 1, 0), text: nil, isSystemText: false).apply(to: &score)
        #expect(Self.texts(score, 1).map(\.0) == ["pizz."])
        #expect(SetStaffText.current(at: Self.slot(Self.cello, 1, 0), isSystemText: false, in: score) == nil)
    }

    @Test("renaming keeps the mark's color and offsets; nil clears; both inverses restore the lane")
    func renameClearUndo() throws {
        var score = EditingFixtures.parityFixture()
        let before = score
        let writeInverse = try SetStaffText(anchor: Self.slot(Self.flute, 2, 0), text: "a", isSystemText: false)
            .apply(to: &score)
        score.systemMeasures[2].elements[0].element = .staffText(StaffText(
            text: "a", offsetX: 2, color: ScoreColor(red: 255, green: 0, blue: 0),
        ))
        let seeded = score
        _ = try SetStaffText(anchor: Self.slot(Self.flute, 2, 0), text: "b", isSystemText: false).apply(to: &score)
        guard case let .staffText(renamed)? = score.systemMeasures[2].elements.first?.element else {
            Issue.record("expected the staff text"); return
        }
        #expect(renamed.text == "b")
        #expect(renamed.offsetX == 2)
        #expect(renamed.color == ScoreColor(red: 255, green: 0, blue: 0))
        let clearInverse = try SetStaffText(anchor: Self.slot(Self.flute, 2, 0), text: nil, isSystemText: false)
            .apply(to: &score)
        #expect(Self.texts(score, 2).isEmpty)
        _ = try clearInverse.apply(to: &score)
        #expect(Self.texts(score, 2).map(\.0) == ["b"])
        _ = try writeInverse.apply(to: &score)
        // The pre-image lane was empty; the write's inverse restores it empty, padding included.
        #expect(score == before)
        #expect(seeded.systemMeasures.count == 4)
    }

    @Test("empty text, a non-timed anchor, a missing anchor and a clear with nothing to clear are refused")
    func refusals() {
        var score = EditingFixtures.parityFixture()
        let before = score
        let empty = #expect(throws: SheetMusicError.self) {
            _ = try SetStaffText(anchor: Self.slot(Self.flute, 0, 1), text: " \n", isSystemText: false)
                .apply(to: &score)
        }
        #expect(Self.reason(of: empty) == .emptyStaffText)
        #expect(throws: SheetMusicError.self) {
            _ = try SetStaffText(anchor: Self.slot(Self.flute, 0, 0), text: "a", isSystemText: false).apply(to: &score)
        }
        #expect(throws: SheetMusicError.self) {
            _ = try SetStaffText(anchor: Self.slot(Self.flute, 4, 0), text: "a", isSystemText: true).apply(to: &score)
        }
        #expect(throws: SheetMusicError.self) {
            _ = try SetStaffText(anchor: Self.slot(Self.flute, 0, 1), text: nil, isSystemText: false).apply(to: &score)
        }
        #expect(score == before)
    }

    private static func reason(of error: SheetMusicError?) -> EditRefusal.Reason? {
        guard case let .invalidEdit(refusal)? = error else { return nil }
        return refusal.reason
    }
}
