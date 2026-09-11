@testable import SheetMusicCore
import Testing

@Suite("Cross-bar input identity classification")
struct CrossBarIdentityTests {
    private typealias Fixture = VoiceIdentityFixtures

    private func session(head: VoiceElement) -> ScoreEditSession {
        ScoreEditSession(score: Fixture.score([
            [Voice(elements: [Fixture.time, .rest(duration: .half), .rest(duration: .quarter), head])],
            [Voice(elements: [.rest(duration: .quarter), .rest(duration: .quarter), .rest(duration: .half)])],
        ]))
    }

    @Test func crossBarChordDurationKeepsHeadIdentity() {
        let session = session(head: Fixture.chord())
        let before = session.score
        let initial = session.idAllocator
        let firstIDs = Fixture.ids(Fixture.elements(before))
        let secondIDs = Fixture.ids(Fixture.elements(before, measure: 1))
        guard case let .chord(originalChord) = Fixture.elements(before)[3] else {
            Issue.record("fixture is a chord")
            return
        }
        let originalNoteID = originalChord.notes.eid(at: 0)
        #expect(session.apply(.setChordDuration(at: Fixture.location(3), duration: .half)))
        #expect(Fixture.ids(Fixture.elements(session.score)) == firstIDs)
        // The head keeps its slot AND its own note identifier now (`CrossBarInputPlanner.piece` no longer
        // re-mints it) — only the tail is new: its slot, then its own note. Two mints, not three.
        #expect(Fixture.ids(Fixture.elements(session.score, measure: 1)) == [
            Fixture.minted(initial, 1), secondIDs[1], secondIDs[2],
        ])
        let expectedHead = VoiceElement.chord(Chord(
            duration: .quarter, notes: [Note(pitch: 60, tpc: 14, tieForward: 1)],
        ))
        let expectedTail = VoiceElement.chord(Chord(
            duration: .quarter, notes: [Note(pitch: 60, tpc: 14, tieBack: 1)],
        ))
        #expect(Fixture.elements(session.score).values == [
            Fixture.time, .rest(duration: .half), .rest(duration: .quarter), expectedHead,
        ])
        #expect(Fixture.elements(session.score, measure: 1).values == [
            expectedTail, .rest(duration: .quarter), .rest(duration: .half),
        ])
        guard case let .chord(head) = Fixture.elements(session.score)[3] else {
            Issue.record("head is a chord")
            return
        }
        guard case let .chord(tail) = Fixture.elements(session.score, measure: 1)[0] else {
            Issue.record("tail is a chord")
            return
        }
        #expect(head.notes.eid(at: 0) == originalNoteID)
        #expect(tail.notes.eid(at: 0) != originalNoteID)
        #expect(session.idAllocator == Fixture.advanced(initial, by: 2))
        #expect(session.undo())
        Fixture.expectSameScore(session.score, before)
    }

    @Test func crossBarRestDurationKeepsHeadIdentity() {
        let session = session(head: .rest(duration: .quarter))
        let before = session.score
        let initial = session.idAllocator
        let firstIDs = Fixture.ids(Fixture.elements(before))
        let secondIDs = Fixture.ids(Fixture.elements(before, measure: 1))
        #expect(session.apply(.setRestDuration(at: Fixture.location(3), duration: .half)))
        #expect(Fixture.ids(Fixture.elements(session.score)) == firstIDs)
        #expect(Fixture.ids(Fixture.elements(session.score, measure: 1)) == [
            Fixture.minted(initial, 1), secondIDs[1], secondIDs[2],
        ])
        #expect(Fixture.elements(session.score).values == [
            Fixture.time, .rest(duration: .half), .rest(duration: .quarter), .rest(duration: .quarter),
        ])
        #expect(Fixture.elements(session.score, measure: 1).values == [
            .rest(duration: .quarter), .rest(duration: .quarter), .rest(duration: .half),
        ])
        #expect(session.idAllocator == Fixture.advanced(initial, by: 1))
        #expect(session.undo())
        Fixture.expectSameScore(session.score, before)
    }

    @Test func crossBarRestOverChordCreatesFreshHead() {
        let session = session(head: Fixture.chord())
        let before = session.score
        let initial = session.idAllocator
        let firstIDs = Fixture.ids(Fixture.elements(before))
        let secondIDs = Fixture.ids(Fixture.elements(before, measure: 1))
        #expect(session.apply(.setRestDuration(at: Fixture.location(3), duration: .half)))
        #expect(Fixture.ids(Fixture.elements(session.score)) == [
            firstIDs[0], firstIDs[1], firstIDs[2], Fixture.minted(initial, 1),
        ])
        #expect(Fixture.ids(Fixture.elements(session.score, measure: 1)) == [
            Fixture.minted(initial, 2), secondIDs[1], secondIDs[2],
        ])
        #expect(Fixture.elements(session.score).values == [
            Fixture.time, .rest(duration: .half), .rest(duration: .quarter), .rest(duration: .quarter),
        ])
        #expect(Fixture.elements(session.score, measure: 1).values == [
            .rest(duration: .quarter), .rest(duration: .quarter), .rest(duration: .half),
        ])
        #expect(session.idAllocator == Fixture.advanced(initial, by: 2))
        #expect(session.undo())
        Fixture.expectSameScore(session.score, before)
    }
}
