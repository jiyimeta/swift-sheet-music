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
        // The element's own slot is kept/restored, so nested minting starts fresh: the chord's own note,
        // then both grace slot lists, then each grace's own note.
        #expect(landed.notes.eid(at: 0) == EID(first: 42, second: 1))
        #expect(F.ids(landed.graceNotesBefore) == [EID(first: 42, second: 2)])
        #expect(F.ids(landed.graceNotesAfter) == [EID(first: 42, second: 3)])
        #expect(landed.graceNotesBefore.values[0].notes.eid(at: 0) == EID(first: 42, second: 4))
        #expect(landed.graceNotesAfter.values[0].notes.eid(at: 0) == EID(first: 42, second: 5))
        #expect(ids.counter == 5)
        for _ in 0 ..< 2 {
            let redo = try inverse.apply(to: &score, ids: &ids)
            V.expectSameScore(score, before)
            try redo.apply(to: &score, ids: &ids)
            V.expectSameScore(score, after)
            #expect(ids.counter == 5)
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
        // The slot's own id mints first, then the widened nested walk: the chord's own note, both grace
        // slot lists, each grace's own note, and only then the tuplet.
        #expect(landed.notes.eid(at: 0) == EID(first: 42, second: 2))
        #expect(F.ids(landed.graceNotesBefore) == [EID(first: 42, second: 3)])
        #expect(F.ids(landed.graceNotesAfter) == [EID(first: 42, second: 4)])
        #expect(landed.graceNotesBefore.values[0].notes.eid(at: 0) == EID(first: 42, second: 5))
        #expect(landed.graceNotesAfter.values[0].notes.eid(at: 0) == EID(first: 42, second: 6))
        #expect(voice.tuplets.eid(at: 0) == EID(first: 42, second: 7))
        #expect(voice.tuplets[0].first == .element(own))
        #expect(voice.tuplets[0].last == .element(own))
        #expect(ids.counter == 7)
        for _ in 0 ..< 2 {
            let redo = try inverse.apply(to: &score, ids: &ids)
            V.expectSameScore(score, before)
            try redo.apply(to: &score, ids: &ids)
            V.expectSameScore(score, after)
            #expect(ids.counter == 7)
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
        // Slot, then the chord's own note, then only the missing grace-array slot, then each grace's own note.
        #expect(landed.notes.eid(at: 0) == EID(first: 42, second: 2))
        #expect(F.ids(landed.graceNotesBefore) == [kept, EID(first: 42, second: 3)])
        #expect(F.ids(landed.graceNotesAfter) == [EID(first: 42, second: 4)])
        #expect(landed.graceNotesBefore.values[0].notes.eid(at: 0) == EID(first: 42, second: 5))
        #expect(landed.graceNotesBefore.values[1].notes.eid(at: 0) == EID(first: 42, second: 6))
        #expect(landed.graceNotesAfter.values[0].notes.eid(at: 0) == EID(first: 42, second: 7))
        #expect(ids.counter == 7)
        let redo = try inverse.apply(to: &score, ids: &ids)
        V.expectSameScore(score, before)
        try redo.apply(to: &score, ids: &ids)
        V.expectSameScore(score, after)
        #expect(ids.counter == 7)
    }

    @Test func clearForCopyRetainsValuesAndAssignmentOnlyFillsMissingIDs() {
        var chord = F.chord(before: [F.grace(), F.grace(61)], after: [F.grace(63)])
        let literal = chord
        var ids = EIDAllocator(actor: 42)
        chord.assignMissingNestedIDs(using: &ids)
        #expect(!chord.hasUnassignedNestedIDs)
        // Mint order: the chord's own note first, then the grace slot lists, then each grace's own note.
        let ownNoteAfterFirstMint = chord.notes.eid(at: 0)
        #expect(ownNoteAfterFirstMint == EID(first: 42, second: 1))
        #expect(F.ids(chord.graceNotesBefore) == [EID(first: 42, second: 2), EID(first: 42, second: 3)])
        #expect(F.ids(chord.graceNotesAfter) == [EID(first: 42, second: 4)])
        #expect(chord.graceNotesBefore.values[0].notes.eid(at: 0) == EID(first: 42, second: 5))
        #expect(chord.graceNotesBefore.values[1].notes.eid(at: 0) == EID(first: 42, second: 6))
        #expect(chord.graceNotesAfter.values[0].notes.eid(at: 0) == EID(first: 42, second: 7))
        chord.assignMissingNestedIDs(using: &ids)
        #expect(ids.counter == 7)
        chord.clearNestedIDsForCopy()
        #expect(chord == literal)
        #expect(chord.hasUnassignedNestedIDs)
        // A copy is different notes throughout, not just different grace slots: the chord's own note and
        // each grace's own note are wiped by the copy clear along with both grace slot lists, so a pasted
        // copy can never land sharing an EID with its source.
        #expect(chord.notes.eid(at: 0) == .invalid)
        #expect(F.ids(chord.graceNotesBefore) == [.invalid, .invalid])
        #expect(F.ids(chord.graceNotesAfter) == [.invalid])
        #expect(chord.graceNotesBefore.values[0].notes.eid(at: 0) == .invalid)
        #expect(chord.graceNotesBefore.values[1].notes.eid(at: 0) == .invalid)
        #expect(chord.graceNotesAfter.values[0].notes.eid(at: 0) == .invalid)
        chord.assignMissingNestedIDs(using: &ids)
        // Same mint order as the first assignment: the chord's own note, both grace slot lists, then each
        // grace's own note — but every one of them is now a fresh mint, none reused from `ownNoteAfterFirstMint`.
        #expect(chord.notes.eid(at: 0) == EID(first: 42, second: 8))
        #expect(chord.notes.eid(at: 0) != ownNoteAfterFirstMint)
        #expect(F.ids(chord.graceNotesBefore) == [EID(first: 42, second: 9), EID(first: 42, second: 10)])
        #expect(F.ids(chord.graceNotesAfter) == [EID(first: 42, second: 11)])
        #expect(chord.graceNotesBefore.values[0].notes.eid(at: 0) == EID(first: 42, second: 12))
        #expect(chord.graceNotesBefore.values[1].notes.eid(at: 0) == EID(first: 42, second: 13))
        #expect(chord.graceNotesAfter.values[0].notes.eid(at: 0) == EID(first: 42, second: 14))
        #expect(ids.counter == 14)
    }
}
