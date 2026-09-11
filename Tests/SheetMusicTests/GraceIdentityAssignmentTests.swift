@testable import SheetMusicCore
import Testing

@Suite("Grace identity assignment")
struct GraceIdentityAssignmentTests {
    private typealias F = GraceIdentityFixtures
    private typealias V = VoiceIdentityFixtures

    private var literal: Score {
        TupletIdentityFixtures.score([
            .chord(F.chord(before: [F.grace(), F.grace(61)], after: [F.grace(63)])),
            .chord(F.chord(before: [F.grace(65)], after: [])), .rest(duration: .quarter),
        ])
    }

    @Test func assignmentUsesDepthFirstOrderAndIsIdempotent() throws {
        var score = literal
        var ids = EIDAllocator(actor: 42)
        score.assignMissingIDs(using: &ids)
        let voice = TupletIdentityFixtures.voice(score)
        let x = try F.chord(score), y = try F.chord(score, index: 1)
        func eid(_ counter: UInt64) -> EID {
            EID(first: 42, second: counter)
        }
        #expect(score.parts.eid(at: 0) == eid(1))
        #expect(score.parts[0].staves.eid(at: 0) == eid(2))
        // Per chord: its element slot, then its own note, then its grace slot lists, then each grace's own note.
        #expect(V.ids(voice.elements) == [eid(3), eid(11), eid(15)])
        #expect(x.notes.eid(at: 0) == eid(4))
        #expect(F.ids(x.graceNotesBefore) == [eid(5), eid(6)])
        #expect(F.ids(x.graceNotesAfter) == [eid(7)])
        #expect(x.graceNotesBefore.values[0].notes.eid(at: 0) == eid(8))
        #expect(x.graceNotesBefore.values[1].notes.eid(at: 0) == eid(9))
        #expect(x.graceNotesAfter.values[0].notes.eid(at: 0) == eid(10))
        #expect(y.notes.eid(at: 0) == eid(12))
        #expect(F.ids(y.graceNotesBefore) == [eid(13)])
        #expect(y.graceNotesBefore.values[0].notes.eid(at: 0) == eid(14))
        #expect(voice.tuplets.eid(at: 0) == eid(16))
        #expect(voice.tuplets[0].first == .element(eid(3)))
        #expect(voice.tuplets[0].last == .element(eid(15)))
        #expect(score.systemMeasures.eid(at: 0) == eid(17))
        #expect(ids.counter == 17)
        #expect(!score.hasUnassignedIDs)
        let assigned = score
        score.assignMissingIDs(using: &ids)
        V.expectSameScore(score, assigned)
        #expect(ids.counter == 17)
    }

    @Test func bareAndEditorNoOpLandEveryLiteralGrace() throws {
        let editor = ScoreEditor(score: literal)
        let before = editor.score
        let allocator = editor.idAllocator
        try editor.apply(GraceIdentityNoOp())
        V.expectSameScore(editor.score, before)
        #expect(editor.idAllocator == allocator)
        var bare = literal
        try GraceIdentityNoOp().apply(to: &bare)
        for score in [editor.score, bare] {
            #expect(!score.hasUnassignedIDs)
            let x = try F.chord(score), y = try F.chord(score, index: 1)
            let nested = F.ids(x.graceNotesBefore) + F.ids(x.graceNotesAfter) + F.ids(y.graceNotesBefore)
            let valid = nested.allSatisfy(\.isValid)
            #expect(valid)
            #expect(Set(nested).count == 4)
        }
    }

    @Test func onlyInvalidGraceIsDetectedAndAssigned() throws {
        var score = ScoreEditor(score: literal).score
        F.mutate(&score) { chord in chord.graceNotesAfter = IdentifiedArray(chord.graceNotesAfter.values) }
        #expect(score.hasUnassignedIDs)
        let before = try F.chord(score)
        var ids = EIDAllocator(actor: 42)
        score.assignMissingIDs(using: &ids)
        let after = try F.chord(score)
        #expect(F.ids(after.graceNotesBefore) == F.ids(before.graceNotesBefore))
        #expect(F.ids(after.graceNotesAfter) == [EID(first: 42, second: 1)])
        #expect(ids.counter == 1)
        #expect(!score.hasUnassignedIDs)
    }

    @Test func valueEqualityAndFingerprintIgnoreGraceIDs() throws {
        var first = literal, second = literal
        var a = EIDAllocator(actor: 42), b = EIDAllocator(actor: 43)
        first.assignMissingIDs(using: &a)
        second.assignMissingIDs(using: &b)
        #expect(first == second)
        #expect(try F.chord(first) == F.chord(second))
        #expect(try F.ids(F.chord(first).graceNotesBefore) != F.ids(F.chord(second).graceNotesBefore))
        #expect(literal.stableFingerprint == first.stableFingerprint)
        #expect(first.stableFingerprint == second.stableFingerprint)
        F.mutate(&second) { chord in chord.graceNotesAfter.updateValue(at: 0) { $0.duration = .sixteenth } }
        #expect(first != second)
        #expect(first.stableFingerprint != second.stableFingerprint)
    }

    #if DEBUG
        @Test func traversalCountsGraceSlotsAndRejectsCrossCollectionDuplicates() throws {
            let score = ScoreEditor(score: literal).score
            let all = EditingIdentityInvariants.identifiers(in: score)
            #expect(all.count == 11)
            #expect(Set(all).count == 11)
            let x = try F.chord(score)
            for shared in [x.graceNotesBefore.eid(at: 0), V.elements(score).eid(at: 0)] {
                var broken = score
                F.mutate(&broken) { chord in
                    chord.graceNotesAfter = IdentifiedArray([(shared, chord.graceNotesAfter[0])])
                }
                #expect(!broken.hasUnassignedIDs)
                #expect(!EditingIdentityInvariants.hasUniqueIDs(broken))
            }
            var crossChord = score
            F.mutate(&crossChord, index: 1) { chord in
                chord.graceNotesBefore = IdentifiedArray([
                    (x.graceNotesBefore.eid(at: 0), chord.graceNotesBefore[0]),
                ])
            }
            #expect(!crossChord.hasUnassignedIDs)
            #expect(!EditingIdentityInvariants.hasUniqueIDs(crossChord))
        }

        @Test func allocatorCoverageIncludesOnlyGraceHighWater() {
            var score = literal
            var ids = EIDAllocator(actor: 42)
            score.assignMissingIDs(using: &ids)
            #expect(EditingIdentityInvariants.allocatorCovers(score, ids))
            F.mutate(&score) { chord in
                chord.graceNotesAfter = IdentifiedArray([(EID(first: 42, second: 18), chord.graceNotesAfter[0])])
            }
            #expect(!score.hasUnassignedIDs)
            #expect(EditingIdentityInvariants.hasUniqueIDs(score))
            #expect(!EditingIdentityInvariants.allocatorCovers(score, ids))
        }
    #endif
}

private struct GraceIdentityNoOp: EditCommand {
    var affectedLocation: VoiceElementID {
        VoiceIdentityFixtures.location(0)
    }

    @discardableResult
    func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        let current = VoiceIdentityFixtures.elements(score)[0]
        return try ReplaceVoiceElement(at: affectedLocation, with: current, identity: .same)
            .apply(to: &score, ids: &ids)
    }
}
