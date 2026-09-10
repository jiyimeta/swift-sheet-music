@testable import SheetMusicCore
import Testing

@Suite("Structural spine identity")
struct StructuralSpineIdentityTests {
    private func score() -> Score {
        Score(division: 480, parts: [
            Part(id: "1", instrument: Instrument(id: "piano"), staves: [Staff(), Staff()]),
            Part(id: "2", instrument: Instrument(id: "flute"), staves: [Staff()]),
        ], systemMeasures: [SystemMeasure()])
    }

    @Test func renameKeepsPartIdentity() throws {
        var score = score()
        var ids = EIDAllocator(actor: 42)
        score.assignMissingIDs(using: &ids)
        let original = score.parts.eid(at: 0)
        try SetPartNames(partIndex: 0, longName: "Grand Piano", shortName: "Pno.").apply(to: &score, ids: &ids)
        #expect(score.parts[0].instrument.longName == "Grand Piano")
        #expect(score.parts.eid(at: 0) == original)
        #expect(ids.counter == 6)
    }

    @Test func clefChangeKeepsStaffIdentity() throws {
        var score = score()
        var ids = EIDAllocator(actor: 42)
        score.assignMissingIDs(using: &ids)
        let original = score.parts[0].staves.eid(at: 1)
        try SetStaffDefaultClef(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 1), newRawType: "F",
        ).apply(to: &score, ids: &ids)
        #expect(score.parts[0].staves[1].defaultClefType == "F")
        #expect(score.parts[0].staves.eid(at: 1) == original)
        #expect(ids.counter == 6)
    }

    @Test func fillingTraversesTheSpineAndPreservesAssignedSlots() {
        var score = score()
        let existing = EID(first: 99, second: 1)
        score.parts = IdentifiedArray([(existing, score.parts[0]), (.invalid, score.parts[1])])
        score.parts.updateValue(at: 0) { part in
            part.staves = IdentifiedArray([(EID(first: 99, second: 2), part.staves[0]), (.invalid, part.staves[1])])
        }
        score.systemMeasures = IdentifiedArray([(EID(first: 99, second: 3), SystemMeasure())])
        var ids = EIDAllocator(actor: 42)
        score.assignMissingIDs(using: &ids)
        #expect(!score.hasUnassignedIDs)
        #expect(score.parts.eid(at: 0) == existing)
        #expect(score.parts.eid(at: 1) == EID(first: 42, second: 1))
        #expect(score.parts[0].staves.eid(at: 0) == EID(first: 99, second: 2))
        #expect(score.parts[0].staves.eid(at: 1) == EID(first: 42, second: 2))
        #expect(score.parts[1].staves.eid(at: 0) == EID(first: 42, second: 3))
        #expect(score.systemMeasures.eid(at: 0) == EID(first: 99, second: 3))
        #expect(ids.counter == 3)
    }

    @Test func equalityIgnoresPartAndStaffIdentity() {
        let bare = score()
        var assigned = bare
        var ids = EIDAllocator(actor: 42)
        assigned.assignMissingIDs(using: &ids)
        #expect(bare.hasUnassignedIDs)
        #expect(!assigned.hasUnassignedIDs)
        #expect(bare == assigned)
    }

    @Test func filteredViewCarriesSurvivingPartAndStaffIdentifiers() {
        var score = score()
        var ids = EIDAllocator(actor: 42)
        score.assignMissingIDs(using: &ids)
        let filtered = score.filtered(hidingStaves: [
            StaffAddress(partIndex: 0, staffIndexInPart: 0),
            StaffAddress(partIndex: 1, staffIndexInPart: 0),
        ])
        #expect(filtered.parts.count == 1)
        #expect(filtered.parts[0].staves.count == 1)
        #expect(filtered.parts.eid(at: 0) == score.parts.eid(at: 0))
        #expect(filtered.parts[0].staves.eid(at: 0) == score.parts[0].staves.eid(at: 1))
        #expect(!filtered.hasUnassignedIDs)
    }
}
