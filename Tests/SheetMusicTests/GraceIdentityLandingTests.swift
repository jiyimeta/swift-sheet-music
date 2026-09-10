@testable import SheetMusicCore
import Testing

@Suite("Grace identity landing")
struct GraceIdentityLandingTests {
    private typealias F = GraceIdentityFixtures
    private typealias V = VoiceIdentityFixtures

    @Test(arguments: 0 ..< 3)
    func existingSlotPoliciesAssignOnlyMissingGraces(_ policy: Int) throws {
        var score = ScoreEditor(score: F.score(before: [], after: [])).score
        let before = score
        let own = V.elements(score).eid(at: 0)
        var ids = EIDAllocator(actor: 42)
        let chord = F.chord(before: [F.grace()], after: [F.grace(61)])
        let command: any EditCommand
        switch policy {
        case 0:
            command = ReplaceVoiceElement(at: V.location(0), with: .chord(chord), identity: .same)
        case 1:
            command = ReplaceVoiceElement(at: V.location(0), with: .chord(chord), identity: .restore(own))
        default:
            command = ReplaceVoiceElements(
                staff: V.staff, measureIndex: 0, voiceIndex: 0,
                slots: [VoiceSlot(identity: .keep(own), element: .chord(chord))],
            )
        }
        let inverse = try command.apply(to: &score, ids: &ids)
        let after = score
        let landed = try F.chord(score)
        #expect(V.elements(score).eid(at: 0) == own)
        #expect(F.ids(landed.graceNotesBefore) == [EID(first: 42, second: 1)])
        #expect(F.ids(landed.graceNotesAfter) == [EID(first: 42, second: 2)])
        #expect(ids.counter == 2)
        for _ in 0 ..< 2 {
            let redo = try inverse.apply(to: &score, ids: &ids)
            V.expectSameScore(score, before)
            try redo.apply(to: &score, ids: &ids)
            V.expectSameScore(score, after)
            #expect(ids.counter == 2)
        }
    }

    @Test func wholeVoicePayloadMintsTupletAfterNestedGraces() throws {
        var score = ScoreEditor(score: V.score(elements: [.rest(duration: .quarter)])).score
        let before = score
        var ids = EIDAllocator(actor: 42)
        let chord = F.chord(before: [F.grace()], after: [F.grace(61)])
        let command = ReplaceVoiceElements(
            staff: V.staff, measureIndex: 0, voiceIndex: 0,
            slots: [VoiceSlot(identity: .fresh, element: .chord(chord))],
            tupletSlots: [TupletSlot(identity: .fresh, tuplet: Tuplet(
                normalNotes: 2, actualNotes: 3, startIndex: 0, endIndex: 0,
            ))],
        )
        let inverse = try command.apply(to: &score, ids: &ids)
        let after = score
        let landed = try F.chord(score)
        let voice = TupletIdentityFixtures.voice(score)
        let own = EID(first: 42, second: 1)
        #expect(voice.elements.eid(at: 0) == own)
        #expect(F.ids(landed.graceNotesBefore) == [EID(first: 42, second: 2)])
        #expect(F.ids(landed.graceNotesAfter) == [EID(first: 42, second: 3)])
        #expect(voice.tuplets.eid(at: 0) == EID(first: 42, second: 4))
        #expect(voice.tuplets[0].first == .element(own))
        #expect(voice.tuplets[0].last == .element(own))
        #expect(ids.counter == 4)
        for _ in 0 ..< 2 {
            let redo = try inverse.apply(to: &score, ids: &ids)
            V.expectSameScore(score, before)
            try redo.apply(to: &score, ids: &ids)
            V.expectSameScore(score, after)
            #expect(ids.counter == 4)
        }
    }

    @Test(arguments: [false, true])
    func replacementAndVoicePayloadMintSlotThenMissingBeforeAndAfter(_ payload: Bool) throws {
        var score = ScoreEditor(score: V.score(elements: [.rest(duration: .quarter)])).score
        let before = score
        var ids = EIDAllocator(actor: 42)
        let kept = EID(first: 99, second: 1)
        var chord = F.chord(before: [F.grace(), F.grace(61)], after: [F.grace(63)])
        chord.graceNotesBefore = IdentifiedArray([
            (kept, chord.graceNotesBefore[0]), (.invalid, chord.graceNotesBefore[1]),
        ])
        let command: any EditCommand = if payload {
            ReplaceVoiceElements(
                staff: V.staff, measureIndex: 0, voiceIndex: 0,
                slots: [VoiceSlot(identity: .fresh, element: .chord(chord))],
            )
        } else {
            ReplaceVoiceElement(at: V.location(0), with: .chord(chord), identity: .fresh)
        }
        let inverse = try command.apply(to: &score, ids: &ids)
        let after = score
        let landed = try F.chord(score)
        #expect(V.elements(score).eid(at: 0) == EID(first: 42, second: 1))
        #expect(F.ids(landed.graceNotesBefore) == [kept, EID(first: 42, second: 2)])
        #expect(F.ids(landed.graceNotesAfter) == [EID(first: 42, second: 3)])
        #expect(ids.counter == 3)
        let redo = try inverse.apply(to: &score, ids: &ids)
        V.expectSameScore(score, before)
        try redo.apply(to: &score, ids: &ids)
        V.expectSameScore(score, after)
        #expect(ids.counter == 3)
    }

    @Test func clearForCopyRetainsValuesAndAssignmentOnlyFillsMissingIDs() {
        var chord = F.chord(before: [F.grace(), F.grace(61)], after: [F.grace(63)])
        let literal = chord
        var ids = EIDAllocator(actor: 42)
        chord.assignMissingGraceIDs(using: &ids)
        #expect(!chord.hasUnassignedGraceIDs)
        #expect(F.ids(chord.graceNotesBefore) == [EID(first: 42, second: 1), EID(first: 42, second: 2)])
        #expect(F.ids(chord.graceNotesAfter) == [EID(first: 42, second: 3)])
        chord.assignMissingGraceIDs(using: &ids)
        #expect(ids.counter == 3)
        chord.clearGraceIDsForCopy()
        #expect(chord == literal)
        #expect(chord.hasUnassignedGraceIDs)
        #expect(F.ids(chord.graceNotesBefore) == [.invalid, .invalid])
        #expect(F.ids(chord.graceNotesAfter) == [.invalid])
        chord.assignMissingGraceIDs(using: &ids)
        #expect(F.ids(chord.graceNotesBefore) == [EID(first: 42, second: 4), EID(first: 42, second: 5)])
        #expect(F.ids(chord.graceNotesAfter) == [EID(first: 42, second: 6)])
        #expect(ids.counter == 6)
    }
}
