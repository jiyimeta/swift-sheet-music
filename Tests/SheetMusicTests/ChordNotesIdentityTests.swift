import SheetMusicCore
import Testing

@Suite("ChordNotes identity")
struct ChordNotesIdentityTests {
    private func allocator() -> EIDAllocator {
        EIDAllocator(actor: 7)
    }

    @Test("an array literal produces unassigned slots")
    func literalSlotsAreUnassigned() {
        let notes: ChordNotes = [Note(pitch: 60, tpc: 14), Note(pitch: 64, tpc: 18)]
        #expect(notes.hasUnassignedIDs)
        #expect(notes.eid(at: 0) == .invalid)
        #expect(notes.count == 2)
    }

    @Test("assignment fills only the unassigned slots")
    func assignmentKeepsAssignedSlots() {
        var ids = allocator()
        let kept = ids.next()
        var notes = ChordNotes([(kept, Note(pitch: 60, tpc: 14)), (.invalid, Note(pitch: 64, tpc: 18))])
        notes.assignMissingIDs(using: &ids)
        #expect(notes.eid(at: 0) == kept)
        #expect(notes.eid(at: 1).isValid)
        #expect(notes.eid(at: 1) != kept)
    }

    @Test("equality ignores identifiers")
    func equalityIgnoresIdentifiers() {
        var ids = allocator()
        let left = ChordNotes([(ids.next(), Note(pitch: 60, tpc: 14))])
        let right = ChordNotes([(ids.next(), Note(pitch: 60, tpc: 14))])
        #expect(left == right)
    }

    @Test("a changed note keeps its slot identifier")
    func updateKeepsIdentity() {
        var ids = allocator()
        var notes = ChordNotes([(ids.next(), Note(pitch: 60, tpc: 14))])
        let before = notes.eid(at: 0)
        #expect(notes.updateNote(at: 0) { $0.accidental = .sharp })
        #expect(notes.eid(at: 0) == before)
        #expect(notes[0].accidental == .sharp)
    }

    @Test("a duplicate pitch is refused and no slot is added")
    func duplicatePitchIsRefused() {
        var ids = allocator()
        var notes = ChordNotes([(ids.next(), Note(pitch: 60, tpc: 14))])
        let appended = notes.tryAppend(Note(pitch: 60, tpc: 14), id: ids.next())
        #expect(!appended)
        #expect(notes.count == 1)
    }

    @Test("an appended note carries the caller's identifier")
    func appendTakesTheCallersIdentifier() {
        var ids = allocator()
        var notes = ChordNotes([(ids.next(), Note(pitch: 60, tpc: 14))])
        let fresh = ids.next()
        let appended = notes.tryAppend(Note(pitch: 64, tpc: 18), id: fresh)
        #expect(appended)
        #expect(notes.eid(at: 1) == fresh)
        #expect(notes[eid: fresh]?.pitch == 64)
    }

    @Test("removing one note leaves the survivors' identifiers alone")
    func removalKeepsSurvivors() {
        var ids = allocator()
        let first = ids.next()
        let second = ids.next()
        var notes = ChordNotes([(first, Note(pitch: 60, tpc: 14)), (second, Note(pitch: 64, tpc: 18))])
        notes.remove(eid: first)
        #expect(notes.count == 1)
        #expect(notes.eid(at: 0) == second)
    }

    @Test("a transposition that collides keeps the first slot and reports the dropped one")
    func mapValuesDedupesFirstWins() {
        var ids = allocator()
        let first = ids.next()
        let second = ids.next()
        var notes = ChordNotes([(first, Note(pitch: 60, tpc: 14)), (second, Note(pitch: 61, tpc: 20))])
        let dropped = notes.mapValues { Note(pitch: 60, tpc: $0.tpc) }
        #expect(notes.count == 1)
        #expect(notes.eid(at: 0) == first)
        #expect(dropped == [second])
    }

    @Test("a transposition that collides with nothing drops nothing")
    func mapValuesReportsNothingWhenNothingCollides() {
        var ids = allocator()
        var notes = ChordNotes([(ids.next(), Note(pitch: 60, tpc: 14)), (ids.next(), Note(pitch: 64, tpc: 18))])
        #expect(notes.mapValues { Note(pitch: $0.pitch + 2, tpc: $0.tpc) }.isEmpty)
        #expect(notes.count == 2)
    }
}
