@testable import SheetMusicCore
import Testing

@Suite("Tuplet identity assignment")
struct TupletIdentityAssignmentTests {
    private typealias F = TupletIdentityFixtures
    private typealias V = VoiceIdentityFixtures

    private var literal: Score {
        F.score([V.chord(), V.chord(), V.chord()])
    }

    @Test func assignmentMintsElementsThenTupletThenColumn() {
        var score = literal
        var ids = EIDAllocator(actor: 42)
        score.assignMissingIDs(using: &ids)
        let voice = F.voice(score)
        #expect(score.parts.eid(at: 0) == EID(first: 42, second: 1))
        #expect(score.parts[0].staves.eid(at: 0) == EID(first: 42, second: 2))
        let elementIDs = (3 ... 5).map { EID(first: 42, second: UInt64($0)) }
        #expect(V.ids(voice.elements) == elementIDs)
        #expect(voice.tuplets.eid(at: 0) == EID(first: 42, second: 6))
        #expect(voice.tuplets[0].first == .element(EID(first: 42, second: 3)))
        #expect(voice.tuplets[0].last == .element(EID(first: 42, second: 5)))
        #expect(score.systemMeasures.eid(at: 0) == EID(first: 42, second: 7))
        #expect(ids.counter == 7)
        #expect(!score.hasUnassignedIDs)
    }

    @Test func editorAndBareConvenienceResolveLiteralEndpoints() throws {
        let editor = ScoreEditor(score: literal)
        var bare = literal
        try ReplaceVoiceElement(at: V.location(1), with: V.chord(), identity: .same).apply(to: &bare)
        for score in [editor.score, bare] {
            let voice = F.voice(score)
            #expect(voice.tuplets[0].first == .element(voice.elements.eid(at: 0)))
            #expect(voice.tuplets[0].last == .element(voice.elements.eid(at: 2)))
            #expect(!score.hasUnassignedIDs)
        }
    }

    @Test func onlyUnassignedTupletMintsOnce() {
        var score = ScoreEditor(score: literal).score
        F.mutate(&score) { voice in voice.tuplets = IdentifiedArray([voice.tuplets[0]]) }
        let old = F.voice(score).tuplets[0]
        var ids = EIDAllocator(actor: 42)
        #expect(score.hasUnassignedIDs)
        score.assignMissingIDs(using: &ids)
        #expect(F.voice(score).tuplets.eid(at: 0) == EID(first: 42, second: 1))
        #expect(F.voice(score).tuplets[0] == old)
        #expect(ids.counter == 1)
        score.assignMissingIDs(using: &ids)
        #expect(ids.counter == 1)
    }

    @Test func unresolvedEndpointAloneIsUnassigned() throws {
        var score = ScoreEditor(score: literal).score
        var ids = EIDAllocator(actor: 42)
        // Intentionally bypass the seams: their out-assert must reject this command's result.
        try UnresolvedTupletEndpointCommand().apply(to: &score, ids: &ids)
        #expect(score.hasUnassignedIDs)
        #expect(ids.counter == 0)
        score.assignMissingIDs(using: &ids)
        #expect(ids.counter == 0)
        #expect(!score.hasUnassignedIDs)
    }

    @Test func fingerprintIgnoresIdentityAndKeepsDanglingTuplets() {
        var first = literal
        var second = literal
        var firstIDs = EIDAllocator(actor: 42)
        var secondIDs = EIDAllocator(actor: 43)
        first.assignMissingIDs(using: &firstIDs)
        second.assignMissingIDs(using: &secondIDs)
        #expect(literal.stableFingerprint == first.stableFingerprint)
        #expect(first.stableFingerprint == second.stableFingerprint)
        F.mutate(&first) { voice in
            voice.tuplets.updateValue(at: 0) { $0.first = .element(EID(first: 99, second: 99)) }
        }
        var negative = literal
        F.mutate(&negative) { voice in voice.tuplets.updateValue(at: 0) { $0.first = .index(-1) } }
        #expect(F.voice(first).tupletSpans.count == 1)
        #expect(F.voice(first).tupletSpans[0].startIndex == -1)
        #expect(first.stableFingerprint == negative.stableFingerprint)
        F.mutate(&negative) { $0.tuplets = [] }
        #expect(first.stableFingerprint != negative.stableFingerprint)
    }

    @Test func payloadResolvesPositionsAfterMaterializingFreshElements() throws {
        var score = ScoreEditor(score: literal).score
        let before = score
        var ids = EIDAllocator(actor: 42)
        let command = ReplaceVoiceElements(
            staff: V.staff, measureIndex: 0, voiceIndex: 0,
            slots: [VoiceSlot(identity: .fresh, element: V.chord())],
            tupletSlots: [TupletSlot(identity: .fresh, tuplet: Tuplet(
                normalNotes: 2, actualNotes: 3, startIndex: 0, endIndex: 0,
            ))],
        )
        let inverse = try command.apply(to: &score, ids: &ids)
        let after = score
        #expect(F.voice(score).elements.eid(at: 0) == EID(first: 42, second: 1))
        #expect(F.voice(score).tuplets.eid(at: 0) == EID(first: 42, second: 2))
        #expect(F.voice(score).tuplets[0].first == .element(EID(first: 42, second: 1)))
        #expect(F.voice(score).tuplets[0].last == .element(EID(first: 42, second: 1)))
        let redo = try inverse.apply(to: &score, ids: &ids)
        V.expectSameScore(score, before)
        try redo.apply(to: &score, ids: &ids)
        V.expectSameScore(score, after)
        #expect(ids.counter == 2)
    }

    #if DEBUG
        @Test func integrityCheckerRejectsUnresolvedForeignUnknownAndReversedEndpoints() {
            let score = ScoreEditor(score: literal).score
            let voice = F.voice(score)
            #expect(EditingIdentityInvariants.hasValidTupletEndpoints(in: score))
            let invalid: [TupletEndpoint] = [.index(0), .element(EID(first: 99, second: 99))]
            for endpoint in invalid {
                var broken = score
                F.mutate(&broken) { value in value.tuplets.updateValue(at: 0) { $0.first = endpoint } }
                #expect(!EditingIdentityInvariants.hasValidTupletEndpoints(in: broken))
                broken = score
                F.mutate(&broken) { value in value.tuplets.updateValue(at: 0) { $0.last = endpoint } }
                #expect(!EditingIdentityInvariants.hasValidTupletEndpoints(in: broken))
            }
            var reversed = score
            F.mutate(&reversed) { value in
                value.tuplets.updateValue(at: 0) {
                    $0.first = .element(voice.elements.eid(at: 2))
                    $0.last = .element(voice.elements.eid(at: 0))
                }
            }
            #expect(!EditingIdentityInvariants.hasValidTupletEndpoints(in: reversed))
            let foreignScore = ScoreEditor(score: V.score([[
                Voice(elements: [V.chord(), V.chord(), V.chord()], tuplets: [F.triplet]),
                Voice(elements: [V.chord()]),
            ]])).score
            var foreign = foreignScore
            let foreignID = F.voice(foreign, voice: 1).elements.eid(at: 0)
            F.mutate(&foreign) { value in value.tuplets.updateValue(at: 0) { $0.last = .element(foreignID) } }
            #expect(!EditingIdentityInvariants.hasValidTupletEndpoints(in: foreign))
            foreign = foreignScore
            F.mutate(&foreign) { value in value.tuplets.updateValue(at: 0) { $0.first = .element(foreignID) } }
            #expect(!EditingIdentityInvariants.hasValidTupletEndpoints(in: foreign))
            let marks = ScoreEditor(score: F.score([F.breath, V.chord(), F.breath])).score
            #expect(EditingIdentityInvariants.hasValidTupletEndpoints(in: marks))
        }

        @Test func identifierTraversalCountsTupletSlotsNotEndpointReferences() {
            let score = ScoreEditor(score: literal).score
            let reported = EditingIdentityInvariants.identifiers(in: score)
            #expect(reported.count == 7)
            #expect(Set(reported).count == 7)
            #expect(reported.contains(F.voice(score).tuplets.eid(at: 0)))
        }
    #endif
}

/// Deliberately violates the resolved-endpoint contract without passing through a seam's out-assert.
private struct UnresolvedTupletEndpointCommand: EditCommand {
    var affectedLocation: VoiceElementID {
        VoiceIdentityFixtures.location(0)
    }

    @discardableResult
    func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        let voice = TupletIdentityFixtures.voice(score)
        let inverse = ReplaceVoiceElements(
            staff: VoiceIdentityFixtures.staff, measureIndex: 0, voiceIndex: 0,
            elements: voice.elements, tuplets: voice.tuplets,
        )
        TupletIdentityFixtures.mutate(&score) { value in
            value.tuplets.updateValue(at: 0) { $0.first = .index(0) }
        }
        return inverse
    }
}
