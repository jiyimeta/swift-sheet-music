@testable import SheetMusicCore
import Testing

@Suite("Structural command identity")
struct StructuralCommandIdentityTests {
    private func score() -> Score {
        let measures = Array(repeating: Measure(voices: [Voice(elements: [.rest(duration: .whole)])]), count: 3)
        return Score(division: 480, parts: IdentifiedArray(["A", "B", "C", "D"].map { name in
            Part(id: name, instrument: Instrument(id: name), staves: [Staff(measures: measures)])
        }), systemMeasures: [SystemMeasure(), SystemMeasure(), SystemMeasure()])
    }

    private func partIDs(_ score: Score) -> [EID] {
        score.parts.indices.map { score.parts.eid(at: $0) }
    }

    private func columnIDs(_ score: Score) -> [EID] {
        score.systemMeasures.indices.map { score.systemMeasures.eid(at: $0) }
    }

    private func checkMove(from: Int, to: Int, expected: [String]) throws {
        var score = score()
        var ids = EIDAllocator(actor: 42)
        score.assignMissingIDs(using: &ids)
        let originalIDs = partIDs(score)
        let inverse = try MovePart(from: from, to: to).apply(to: &score, ids: &ids)
        #expect(score.parts.map(\.id) == expected)
        #expect(score.parts.eid(at: to) == originalIDs[from])
        #expect(Set(partIDs(score)) == Set(originalIDs))
        try inverse.apply(to: &score, ids: &ids)
        #expect(score.parts.map(\.id) == ["A", "B", "C", "D"])
        #expect(partIDs(score) == originalIDs)
        #expect(Set(partIDs(score)) == Set(originalIDs))
        #expect(ids.counter == 11)
    }

    @Test func forwardMoveCarriesIdentityAndItsInverseRestoresIt() throws {
        try checkMove(from: 0, to: 2, expected: ["B", "C", "A", "D"])
    }

    @Test func backwardMoveCarriesIdentityAndItsInverseRestoresIt() throws {
        try checkMove(from: 3, to: 1, expected: ["A", "D", "B", "C"])
    }

    @Test func moveToZeroCarriesIdentityAndItsInverseRestoresIt() throws {
        try checkMove(from: 2, to: 0, expected: ["C", "A", "B", "D"])
    }

    @Test func deleteInverseRestoresColumnIdentifiersInOrderAndAsASet() throws {
        var score = score()
        var ids = EIDAllocator(actor: 42)
        score.assignMissingIDs(using: &ids)
        let original = columnIDs(score)
        let inverse = try DeleteMeasure(measureIndex: 1).apply(to: &score, ids: &ids)
        #expect(columnIDs(score) == [original[0], original[2]])
        try inverse.apply(to: &score, ids: &ids)
        #expect(columnIDs(score) == original)
        #expect(Set(columnIDs(score)) == Set(original))
        #expect(ids.counter == 11)
    }

    @Test func removeInverseRestoresPartIdentifiersInOrderAndAsASet() throws {
        var score = score()
        var ids = EIDAllocator(actor: 42)
        score.assignMissingIDs(using: &ids)
        let original = partIDs(score)
        let inverse = try RemovePart(partIndex: 1).apply(to: &score, ids: &ids)
        #expect(partIDs(score) == [original[0], original[2], original[3]])
        try inverse.apply(to: &score, ids: &ids)
        #expect(score.parts.map(\.id) == ["A", "B", "C", "D"])
        #expect(partIDs(score) == original)
        #expect(Set(partIDs(score)) == Set(original))
        #expect(ids.counter == 11)
    }

    @Test func blankInsertMintsOnlyTheNewColumn() throws {
        var score = score()
        var ids = EIDAllocator(actor: 42)
        score.assignMissingIDs(using: &ids)
        let original = columnIDs(score)
        try InsertMeasure(measureIndex: 1).apply(to: &score, ids: &ids)
        let inserted = EID(first: 42, second: 12)
        #expect(columnIDs(score) == [original[0], inserted, original[1], original[2]])
        #expect(!Set(original).contains(inserted))
        #expect(ids.counter == 12)
    }

    @Test func deleteInverseKeepsAnAbsentSystemLaneAbsent() throws {
        var score = score()
        score.systemMeasures = []
        var ids = EIDAllocator(actor: 42)
        score.assignMissingIDs(using: &ids)
        let inverse = try DeleteMeasure(measureIndex: 1).apply(to: &score, ids: &ids)
        #expect(score.systemMeasures.isEmpty)
        #expect(MeasureStructure.measureCount(of: score) == 2)
        try inverse.apply(to: &score, ids: &ids)
        #expect(score.systemMeasures.isEmpty)
        #expect(MeasureStructure.measureCount(of: score) == 3)
        #expect(ids.counter == 8)
    }
}
