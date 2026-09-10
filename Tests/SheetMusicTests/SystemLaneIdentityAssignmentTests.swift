@testable import SheetMusicCore
import Testing

@Suite("System lane identity assignment")
struct SystemLaneIdentityAssignmentTests {
    private typealias V = VoiceIdentityFixtures

    private var literal: Score {
        var score = V.score([
            [Voice(elements: [.rest(duration: .whole)])],
            [Voice(elements: [.rest(duration: .whole)])],
        ])
        score.systemMeasures = [
            SystemMeasure(elements: [
                PositionedSystemElement(position: .start, element: .tempo(Tempo(beatsPerSecond: 2))),
                PositionedSystemElement(position: .start, element: .staffText(StaffText(text: "pizz."))),
            ]),
            SystemMeasure(elements: [
                PositionedSystemElement(position: .start, element: .rehearsalMark(RehearsalMark(text: "A"))),
            ]),
        ]
        return score
    }

    @Test func assignmentMintsAllColumnsBeforeTheirOccupants() {
        var score = literal
        var ids = EIDAllocator(actor: 42)
        let initial = ids
        score.assignMissingIDs(using: &ids)
        #expect(score.parts.eid(at: 0) == V.minted(initial, 1))
        #expect(score.parts[0].staves.eid(at: 0) == V.minted(initial, 2))
        #expect(V.elements(score).eid(at: 0) == V.minted(initial, 3))
        #expect(V.elements(score, measure: 1).eid(at: 0) == V.minted(initial, 4))
        #expect(score.systemMeasures.eid(at: 0) == V.minted(initial, 5))
        #expect(score.systemMeasures.eid(at: 1) == V.minted(initial, 6))
        #expect(score.systemMeasures[0].elements.eid(at: 0) == V.minted(initial, 7))
        #expect(score.systemMeasures[0].elements.eid(at: 1) == V.minted(initial, 8))
        #expect(score.systemMeasures[1].elements.eid(at: 0) == V.minted(initial, 9))
        #expect(ids.counter == 9)
        #expect(!score.hasUnassignedIDs)
        let assigned = score
        score.assignMissingIDs(using: &ids)
        V.expectSameScore(score, assigned)
        #expect(ids.counter == 9)
    }

    @Test func bareAndEditorEntryAssignLiteralOccupants() throws {
        let editor = ScoreEditor(score: literal)
        #expect(editor.idAllocator.counter == 9)
        #expect(!editor.score.hasUnassignedIDs)
        var bare = literal
        try ReplaceVoiceElement(at: V.location(0), with: .rest(duration: .whole), identity: .same)
            .apply(to: &bare)
        #expect(!bare.hasUnassignedIDs)
        #expect(bare == editor.score)
        let occupants = bare.systemMeasures.flatMap { column in
            column.elements.indices.map { column.elements.eid(at: $0) }
        }
        let valid = occupants.allSatisfy(\.isValid)
        #expect(valid)
        #expect(Set(occupants).count == 3)
        let counters = occupants.map(\.second)
        #expect(counters == [7, 8, 9])
    }

    @Test func assignmentFillsOnlyTheUnassignedLaneSlots() {
        var score = ScoreEditor(score: literal).score
        let before = score
        score.systemMeasures.updateValue(at: 1) { column in
            column.elements = IdentifiedArray(column.elements.values)
        }
        #expect(score.hasUnassignedIDs)
        var ids = EIDAllocator(actor: 42)
        score.assignMissingIDs(using: &ids)
        #expect(!score.hasUnassignedIDs)
        #expect(score.systemMeasures[1].elements.eid(at: 0) == EID(first: 42, second: 1))
        #expect(score.systemMeasures[0].elements.eid(at: 0) == before.systemMeasures[0].elements.eid(at: 0))
        #expect(score.systemMeasures[0].elements.eid(at: 1) == before.systemMeasures[0].elements.eid(at: 1))
        #expect(V.spineIDs(score) == V.spineIDs(before))
        #expect(V.voiceIDs(score) == V.voiceIDs(before))
        #expect(ids.counter == 1)
    }

    @Test func equalityAndFingerprintIgnoreOnlyLaneIdentity() {
        var first = literal
        var ids = EIDAllocator(actor: 42)
        first.assignMissingIDs(using: &ids)
        var second = first
        second.systemMeasures.updateValue(at: 0) { column in
            column.elements = IdentifiedArray([
                (EID(first: 43, second: 1), column.elements[0]),
                (EID(first: 43, second: 2), column.elements[1]),
            ])
        }
        #expect(first.systemMeasures[0] == second.systemMeasures[0])
        #expect(first == second)
        #expect(first.stableFingerprint == second.stableFingerprint)
        second.systemMeasures.updateValue(at: 0) { column in
            column.elements.updateValue(at: 0) { $0.position = MeasurePosition(numerator: 1, denominator: 4) }
        }
        #expect(first != second)
        #expect(first.stableFingerprint != second.stableFingerprint)
        first.systemMeasures = []
        second.systemMeasures = [SystemMeasure(), SystemMeasure()]
        #expect(first.stableFingerprint == second.stableFingerprint)
    }

    #if DEBUG
        @Test func traversalRejectsLaneAndCrossCollectionDuplicates() {
            let score = ScoreEditor(score: literal).score
            let all = EditingIdentityInvariants.identifiers(in: score)
            #expect(all.count == 9)
            #expect(Set(all).count == 9)
            for shared in [
                score.systemMeasures[0].elements.eid(at: 0),
                score.systemMeasures.eid(at: 0), V.elements(score).eid(at: 0),
            ] {
                var broken = score
                broken.systemMeasures.updateValue(at: 1) { column in
                    column.elements = IdentifiedArray([(shared, column.elements[0])])
                }
                #expect(!broken.hasUnassignedIDs)
                #expect(!EditingIdentityInvariants.hasUniqueIDs(broken))
            }
        }

        @Test func highWaterAndRestorationGatesIncludeLaneSlots() {
            var score = literal
            var ids = EIDAllocator(actor: 42)
            score.assignMissingIDs(using: &ids)
            let before = Set(EditingIdentityInvariants.identifiers(in: score))
            #expect(EditingIdentityInvariants.allocatorCovers(score, ids))
            score.systemMeasures.updateValue(at: 1) { column in
                column.elements = IdentifiedArray([(EID(first: 42, second: 10), column.elements[0])])
            }
            #expect(!score.hasUnassignedIDs)
            #expect(EditingIdentityInvariants.hasUniqueIDs(score))
            #expect(!EditingIdentityInvariants.allocatorCovers(score, ids))
            let after = Set(EditingIdentityInvariants.identifiers(in: score))
            #expect(!EditingIdentityInvariants.restoresIDs(before, after: after))
            #expect(!EditingIdentityInvariants.restoresIDs(after, after: before))
        }
    #endif
}
