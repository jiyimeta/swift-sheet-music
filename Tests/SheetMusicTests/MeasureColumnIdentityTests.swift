@testable import SheetMusicCore
import Testing

@Suite("Measure column identity")
struct MeasureColumnIdentityTests {
    private let firstID = EID(first: 42, second: 1)
    private let secondID = EID(first: 42, second: 2)

    private func column(_ tempo: Double) -> SystemMeasure {
        SystemMeasure(elements: [PositionedSystemElement(
            position: .start, element: .tempo(Tempo(beatsPerSecond: tempo)),
        )])
    }

    private func bareScore() -> Score {
        var score = EditingFixtures.twoMeasuresOfQuarterRests()
        score.systemMeasures = [column(1), column(2)]
        return score
    }

    private func assignedScore() -> Score {
        var score = bareScore()
        score.systemMeasures = IdentifiedArray([(firstID, column(1)), (secondID, column(2))])
        return score
    }

    @Test func valuesPreserveOrderAndCount() {
        let lane = assignedScore().systemMeasures
        #expect(lane.values == [column(1), column(2)])
        #expect(lane.values.count == lane.count)
    }

    @Test func fingerprintIgnoresColumnIdentifiers() {
        let bare = bareScore()
        let assigned = assignedScore()
        #expect(bare.hasUnassignedIDs)
        #expect(!assigned.hasUnassignedIDs)
        #expect(bare.stableFingerprint == assigned.stableFingerprint)
    }

    @Test func propertyUpdateKeepsColumnIdentity() {
        var lane = assignedScore().systemMeasures
        lane.updateValue(at: 0) { $0.elements.removeAll() }
        #expect(lane[0].elements.isEmpty)
        #expect(lane.eid(at: 0) == firstID)
        #expect(lane.eid(at: 1) == secondID)
    }

    @Test func paddingMintsOnlyTheNewColumns() {
        var score = EditingFixtures.threeMeasuresOfQuarterRests()
        score.systemMeasures = IdentifiedArray([(firstID, column(1))])
        var ids = EIDAllocator(actor: 42, counter: 1)
        RehearsalMarkLane.pad(&score, ids: &ids)
        #expect(score.systemMeasures.count == 3)
        #expect(score.systemMeasures.eid(at: 0) == firstID)
        #expect(score.systemMeasures.eid(at: 1) == EID(first: 42, second: 2))
        #expect(score.systemMeasures.eid(at: 2) == EID(first: 42, second: 3))
        #expect(!score.hasUnassignedIDs)
        #expect(ids.counter == 3)
    }

    @Test func insertingAtZeroPlacesTheColumnAtTheFront() throws {
        var score = assignedScore()
        var ids = EIDAllocator(actor: 42, counter: 2)
        try InsertMeasure(measureIndex: 0).apply(to: &score, ids: &ids)
        #expect(score.systemMeasures.values == [SystemMeasure(), column(1), column(2)])
        #expect(score.systemMeasures.eid(at: 0) == EID(first: 42, second: 3))
        #expect(score.systemMeasures.eid(at: 1) == firstID)
        #expect(score.systemMeasures.eid(at: 2) == secondID)
    }

    @Test func insertingAtCountPlacesTheColumnAtTheEnd() throws {
        var score = assignedScore()
        var ids = EIDAllocator(actor: 42, counter: 2)
        try InsertMeasure(measureIndex: 2).apply(to: &score, ids: &ids)
        #expect(score.systemMeasures.values == [column(1), column(2), SystemMeasure()])
        #expect(score.systemMeasures.eid(at: 0) == firstID)
        #expect(score.systemMeasures.eid(at: 1) == secondID)
        #expect(score.systemMeasures.eid(at: 2) == EID(first: 42, second: 3))
    }

    @Test func bareCommandFillsUnassignedColumnsOnEntry() throws {
        var score = bareScore()
        try CompositeEditCommand(commands: [], location: DropColumnIDs().affectedLocation).apply(to: &score)
        #expect(!score.hasUnassignedIDs)
        #expect(score.systemMeasures.values == [column(1), column(2)])
    }

    @Test func bareDeleteRemovesTheColumnAndKeepsTheLaneParallel() throws {
        var score = bareScore()
        try DeleteMeasure(measureIndex: 0).apply(to: &score)
        #expect(score.systemMeasures.values == [column(2)])
        #expect(score.systemMeasures.count == MeasureStructure.measureCount(of: score))
        #expect(!score.hasUnassignedIDs)
    }

    @Test func bareMiddleInsertUsesTheAssignedPredecessor() throws {
        var score = bareScore()
        try InsertMeasure(measureIndex: 1).apply(to: &score)
        #expect(score.systemMeasures.values == [column(1), SystemMeasure(), column(2)])
        #expect(score.systemMeasures.count == MeasureStructure.measureCount(of: score))
        #expect(!score.hasUnassignedIDs)
    }

    @Test func aLaneRebuiltFromALiteralIsDetectableBeforeTheOutAssert() throws {
        var score = assignedScore()
        var ids = EIDAllocator(actor: 42, counter: 2)
        score.assignMissingIDs(using: &ids)
        try DropColumnIDs().apply(to: &score, ids: &ids)
        #expect(score.hasUnassignedIDs)
        #expect(ids.counter == 2)
    }

    @Test func editorFillsOnEntryAndPreservesAssignedIDsAcrossUndoRedo() throws {
        let editor = ScoreEditor(score: bareScore())
        let command = CompositeEditCommand(commands: [], location: DropColumnIDs().affectedLocation)
        try editor.apply(command)
        let first = editor.score.systemMeasures.eid(at: 0)
        #expect(!editor.score.hasUnassignedIDs)
        #expect(editor.idAllocator.counter == 2)
        try editor.undo()
        #expect(editor.score.systemMeasures.eid(at: 0) == first)
        try editor.redo()
        #expect(editor.score.systemMeasures.eid(at: 0) == first)
        #expect(editor.idAllocator.counter == 2)
    }
}

private struct DropColumnIDs: EditCommand {
    var affectedLocation: VoiceElementID {
        VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 0, voiceIndex: 0, elementIndex: 0,
        )
    }

    @discardableResult
    func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        score.systemMeasures = [SystemMeasure(), SystemMeasure()]
        return self
    }
}
