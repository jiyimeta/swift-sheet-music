@testable import SheetMusicCore
import Testing

@Suite("System lane identity structure")
struct SystemLaneIdentityStructureTests {
    private typealias V = VoiceIdentityFixtures

    private func markedScore() -> Score {
        var score = V.score([
            [Voice(elements: [V.time, .rest(duration: .whole)])],
            [Voice(elements: [.rest(duration: .whole)])],
            [Voice(elements: [.rest(duration: .whole)])],
        ])
        score.systemMeasures = IdentifiedArray((0 ..< 3).map { index in
            SystemMeasure(elements: [PositionedSystemElement(
                position: .start, element: .tempo(Tempo(beatsPerSecond: Double(index + 1))),
            )])
        })
        return score
    }

    private func laneIDs(_ score: Score) -> [[EID]] {
        score.systemMeasures.map { column in column.elements.indices.map { column.elements.eid(at: $0) } }
    }

    private func expectCycle(
        _ editor: ScoreEditor, before: Score, sourceLocation: SourceLocation = #_sourceLocation,
    ) throws {
        let after = editor.score
        let allocator = editor.idAllocator
        try editor.undo()
        V.expectSameScore(editor.score, before, sourceLocation: sourceLocation)
        #expect(editor.idAllocator == allocator, sourceLocation: sourceLocation)
        try editor.redo()
        V.expectSameScore(editor.score, after, sourceLocation: sourceLocation)
        #expect(editor.idAllocator == allocator, sourceLocation: sourceLocation)
        try editor.undo()
        V.expectSameScore(editor.score, before, sourceLocation: sourceLocation)
        #expect(editor.idAllocator == allocator, sourceLocation: sourceLocation)
    }

    @Test func rebarTransportsMarkerPairsAndRestoresExactly() throws {
        var literal = V.score(elements: [V.time, .rest(duration: .whole)])
        literal.systemMeasures = [SystemMeasure(elements: [
            PositionedSystemElement(position: .start, element: .tempo(Tempo(beatsPerSecond: 2))),
            PositionedSystemElement(
                position: MeasurePosition(numerator: 1, denominator: 2),
                element: .rehearsalMark(RehearsalMark(text: "B")),
            ),
        ])]
        let editor = ScoreEditor(score: literal)
        let before = editor.score
        let initial = editor.idAllocator
        let oldVoice = V.ids(V.elements(before))
        let oldLane = laneIDs(before)[0]
        try editor.apply(SetTimeSignature(measureIndex: 0, numerator: 2, denominator: 4))
        #expect(V.voiceIDs(editor.score) == [[oldVoice[0], oldVoice[1]], [V.minted(initial, 1)]])
        #expect(editor.score.systemMeasures.eid(at: 0) == before.systemMeasures.eid(at: 0))
        #expect(editor.score.systemMeasures.eid(at: 1) == V.minted(initial, 2))
        #expect(laneIDs(editor.score) == [[oldLane[0]], [oldLane[1]]])
        #expect(editor.score.systemMeasures[0].elements[0] == before.systemMeasures[0].elements[0])
        #expect(editor.score.systemMeasures[1].elements[0].element == before.systemMeasures[0].elements[1].element)
        #expect(editor.score.systemMeasures[1].elements[0].position == .start)
        #expect(editor.idAllocator == V.advanced(initial, by: 2))
        try expectCycle(editor, before: before)
    }

    @Test(arguments: [0, 1])
    func insertMeasureKeepsLaneOccupantsThroughRepeatedUndo(_ index: Int) throws {
        let editor = ScoreEditor(score: markedScore())
        let before = editor.score
        let initial = editor.idAllocator
        let oldLane = laneIDs(before)
        try editor.apply(InsertMeasure(measureIndex: index))
        var expected = oldLane
        expected.insert([], at: index)
        #expect(laneIDs(editor.score) == expected)
        #expect(editor.score.systemMeasures.eid(at: index) == V.minted(initial, 2))
        let inserted = V.elements(editor.score, measure: index)
        let foundRest = inserted.firstIndex(where: \.isRest)
        let restIndex = try #require(foundRest)
        #expect(inserted.eid(at: restIndex) == V.minted(initial, 1))
        #expect(editor.idAllocator == V.advanced(initial, by: 2))
        try expectCycle(editor, before: before)
    }

    @Test(arguments: [0, 1])
    func deleteMeasureRestoresLaneOccupantsThroughRepeatedUndo(_ index: Int) throws {
        let editor = ScoreEditor(score: markedScore())
        let before = editor.score
        let initial = editor.idAllocator
        var expected = laneIDs(before)
        expected.remove(at: index)
        try editor.apply(DeleteMeasure(measureIndex: index))
        #expect(laneIDs(editor.score) == expected)
        #expect(editor.idAllocator == initial)
        try expectCycle(editor, before: before)
    }
}
