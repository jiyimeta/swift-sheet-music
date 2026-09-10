@testable import SheetMusicCore
import Testing

@Suite("System lane mark identity")
struct SystemLaneMarkIdentityTests {
    typealias F = SystemLaneIdentityFixtures
    private typealias V = VoiceIdentityFixtures

    @Test(arguments: F.Mark.allCases)
    func changeKeepsIdentity(_ mark: F.Mark) throws {
        let editor = ScoreEditor(score: F.score([mark.value()]))
        let before = editor.score
        let initial = editor.idAllocator
        try editor.apply(mark.command())
        #expect(F.ids(editor.score) == F.ids(before))
        #expect(editor.score.systemMeasures[0].elements.values == [mark.value(changed: true)])
        #expect(editor.idAllocator == initial)
        try F.expectCycle(editor, before: before)
    }

    @Test(arguments: F.Mark.allCases)
    func insertionMintsOnlyTheOccupant(_ mark: F.Mark) throws {
        let editor = ScoreEditor(score: F.score([]))
        let before = editor.score
        let initial = editor.idAllocator
        try editor.apply(mark.command())
        #expect(F.ids(editor.score) == [V.minted(initial, 1)])
        #expect(editor.score.systemMeasures[0].elements.values == [mark.value(changed: true)])
        #expect(editor.idAllocator == V.advanced(initial, by: 1))
        try F.expectCycle(editor, before: before)
    }

    @Test(arguments: F.Mark.allCases)
    func removalRestoresVerbatim(_ mark: F.Mark) throws {
        let editor = ScoreEditor(score: F.score([mark.value()]))
        let before = editor.score
        let initial = editor.idAllocator
        try editor.apply(mark.command(removing: true))
        #expect(editor.score.systemMeasures[0].elements.isEmpty)
        #expect(editor.idAllocator == initial)
        try F.expectCycle(editor, before: before)
    }

    @Test(arguments: F.Mark.allCases)
    func paddingMintsColumnsBeforeOccupant(_ mark: F.Mark) throws {
        var literal = F.score([], measures: 2)
        literal.systemMeasures = []
        let editor = ScoreEditor(score: literal)
        let before = editor.score
        let initial = editor.idAllocator
        try editor.apply(mark.command())
        #expect(editor.score.systemMeasures.eid(at: 0) == V.minted(initial, 1))
        #expect(editor.score.systemMeasures.eid(at: 1) == V.minted(initial, 2))
        #expect(F.ids(editor.score) == [V.minted(initial, 3)])
        #expect(editor.idAllocator == V.advanced(initial, by: 3))
        try F.expectCycle(editor, before: before)
    }

    @Test(arguments: F.Mark.allCases)
    func duplicateCollapseKeepsFirstAndUnrelatedSlots(_ mark: F.Mark) throws {
        var unrelated = F.Mark.tempo.value()
        unrelated.position = MeasurePosition(numerator: 1, denominator: 2)
        // The dropped duplicate sits BEFORE the unrelated survivor, so re-pairing survivors with the old EID list in
        // order would hand the survivor the duplicate's EID and fail here.
        let editor = ScoreEditor(score: F.score([mark.value(), mark.value(), unrelated]))
        let before = editor.score
        let old = F.ids(before)
        let initial = editor.idAllocator
        try editor.apply(mark.command())
        #expect(F.ids(editor.score) == [old[0], old[2]])
        #expect(editor.score.systemMeasures[0].elements.values == [mark.value(changed: true), unrelated])
        #expect(editor.idAllocator == initial)
        try F.expectCycle(editor, before: before)
    }
}
