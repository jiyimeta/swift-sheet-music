@testable import SheetMusicCore
import Testing

@Suite("Session preview identity replay")
struct SessionPreviewIdentityTests {
    private typealias Fixture = VoiceIdentityFixtures

    @Test func keyChangeRepairsKeepPreviewMintedSignature() throws {
        let session = ScoreEditSession(score: Fixture.score([
            [Voice(elements: [
                .keySignature(KeySignature(concertKey: 0)), Fixture.time, .rest(duration: .measure),
            ])],
            [Voice(elements: [Fixture.chord(.whole, pitch: 65, tpc: 13)])],
        ]))
        let before = session.score
        let initial = session.idAllocator
        let chordID = Fixture.elements(before, measure: 1).eid(at: 0)
        let plan = try ScoreEditSession.keyChangePlan(
            SetKeySignature(measureIndex: 1, concertKey: 1), in: before, ids: initial,
        )
        let expected = [Fixture.minted(initial, 1), chordID]
        #expect(Fixture.ids(Fixture.elements(plan.preview, measure: 1)) == expected)
        #expect(Fixture.elements(plan.preview, measure: 1).values == [
            .keySignature(KeySignature(concertKey: 1)), Fixture.chord(.whole, pitch: 65, tpc: 13),
        ])
        #expect(plan.idAllocator == Fixture.advanced(initial, by: 1))
        #expect(plan.repairs.count == 1)
        let repair = try #require(plan.repairs.first as? ReplaceVoiceElements)
        let identities = repair.slots.map(\.identity)
        let expectedIdentities = expected.map { SlotIdentity.keep($0) }
        #expect(identities == expectedIdentities)
        let repairedChord = VoiceElement.chord(Chord(
            duration: .whole, notes: [Note(pitch: 65, tpc: 13, accidental: .natural)],
        ))
        let repairedElements = repair.slots.map(\.element)
        #expect(repairedElements == [.keySignature(KeySignature(concertKey: 1)), repairedChord])
        let planned = try ScoreEditSession.setKeySignatureCommand(at: 1, concertKey: 1, in: before, ids: initial)
        let command = try #require(planned)
        let outer = try #require(ScoreEditSession.renotationPlan(command, from: before, ids: initial))
        #expect(outer.repairs.isEmpty)
        #expect(outer.idAllocator == plan.idAllocator)
        #expect(Fixture.voiceIDs(outer.preview) == Fixture.voiceIDs(plan.preview))
        Fixture.expectSameScore(session.score, before)
        #expect(session.idAllocator == initial)
        #expect(session.apply(.setKeySignature(measureIndex: 1, concertKey: 1)))
        Fixture.expectSameScore(session.score, outer.preview)
        #expect(Fixture.elements(session.score, measure: 1)[1] == repairedChord)
        #expect(session.idAllocator == plan.idAllocator)
    }

    @Test func sessionDiffRepairsKeepPreviewMintedRest() throws {
        let first = VoiceElement.chord(Chord(
            duration: .quarter, notes: [Note(pitch: 61, tpc: 21, accidental: .sharp)],
        ))
        let second = Fixture.chord(.quarter, pitch: 61, tpc: 21)
        let session = ScoreEditSession(score: Fixture.score(elements: [first, second, .rest(duration: .half)]))
        let before = session.score
        let initial = session.idAllocator
        let old = Fixture.ids(Fixture.elements(before))
        let intent = EditIntent.delete(at: Fixture.location(0))
        let planned = try ScoreEditSession.command(for: intent, in: before, ids: initial, depth: 0)
        let command = try #require(planned)
        let plan = try #require(ScoreEditSession.renotationPlan(command, from: before, ids: initial))
        let expected = [Fixture.minted(initial, 1), old[1], old[2]]
        #expect(Fixture.ids(Fixture.elements(plan.preview)) == expected)
        #expect(Fixture.elements(plan.preview).values == [.rest(duration: .quarter), second, .rest(duration: .half)])
        #expect(plan.idAllocator == Fixture.advanced(initial, by: 1))
        #expect(plan.repairs.count == 1)
        let repair = try #require(plan.repairs.first as? ReplaceVoiceElements)
        let identities = repair.slots.map(\.identity)
        let expectedIdentities = expected.map { SlotIdentity.keep($0) }
        let repairedElements = repair.slots.map(\.element)
        #expect(identities == expectedIdentities)
        #expect(repairedElements == [.rest(duration: .quarter), first, .rest(duration: .half)])
        Fixture.expectSameScore(session.score, before)
        #expect(session.idAllocator == initial)
        #expect(session.apply(intent))
        #expect(Fixture.voiceIDs(session.score) == Fixture.voiceIDs(plan.preview))
        #expect(Fixture.spineIDs(session.score) == Fixture.spineIDs(before))
        #expect(Fixture.elements(session.score).values == [.rest(duration: .quarter), first, .rest(duration: .half)])
        #expect(session.idAllocator == plan.idAllocator)
        let applied = session.score
        #expect(session.undo())
        Fixture.expectSameScore(session.score, before)
        #expect(session.redo())
        Fixture.expectSameScore(session.score, applied)
        #expect(session.idAllocator == plan.idAllocator)
    }
}
