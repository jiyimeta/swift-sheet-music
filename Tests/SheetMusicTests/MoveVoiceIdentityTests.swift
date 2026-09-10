@testable import SheetMusicCore
import Testing

@Suite("Move voice identity")
struct MoveVoiceIdentityTests {
    private typealias Fixture = VoiceIdentityFixtures

    private var source: Voice {
        Voice(elements: [.rest(duration: .quarter), Fixture.chord(), .rest(duration: .half)])
    }

    private var move: MoveToVoice {
        MoveToVoice(
            at: Fixture.location(1),
            to: VoiceRef(staff: Fixture.staff, measureIndex: 0, voiceIndex: 1),
        )
    }

    @Test func movePlanReplaysCreatedAndSplitVoiceIdentifiers() throws {
        let editor = ScoreEditor(score: Fixture.score([[source]]))
        let before = editor.score
        let initial = editor.idAllocator
        let old = Fixture.ids(Fixture.elements(before))
        let plan = try move.plan(in: before, ids: initial)
        let expectedSource = [old[0], Fixture.minted(initial, 4), old[2]]
        let expectedDestination = [Fixture.minted(initial, 1), old[1], Fixture.minted(initial, 3)]
        #expect(plan.commands.count == 4)
        #expect(Fixture.voiceIDs(plan.result) == [expectedSource, expectedDestination])
        #expect(Fixture.elements(plan.result).values == [
            .rest(duration: .quarter), .rest(duration: .quarter), .rest(duration: .half),
        ])
        #expect(Fixture.elements(plan.result, voice: 1).values == source.elements.values)
        #expect(plan.idAllocator == Fixture.advanced(initial, by: 4))
        Fixture.expectSameScore(editor.score, before)
        #expect(editor.idAllocator == initial)
        let sourceWrite = try #require(plan.commands[2] as? ReplaceVoiceElement)
        let destinationWrite = try #require(plan.commands[3] as? ReplaceVoiceElements)
        #expect(sourceWrite.identity == .fresh)
        #expect(sourceWrite.location == Fixture.location(1))
        #expect(destinationWrite.slots[1].identity == .keep(old[1]))
        var replay = before
        var replayIDs = initial
        for step in plan.commands {
            try step.apply(to: &replay, ids: &replayIDs)
            let identifiers = Fixture.allIDs(replay)
            #expect(Set(identifiers).count == identifiers.count)
        }
        Fixture.expectSameScore(replay, plan.result)
        #expect(replayIDs == plan.idAllocator)
        try editor.apply(move)
        Fixture.expectSameScore(editor.score, plan.result)
        #expect(editor.idAllocator == plan.idAllocator)
        try editor.undo()
        Fixture.expectSameScore(editor.score, before)
        try editor.redo()
        Fixture.expectSameScore(editor.score, plan.result)
        #expect(editor.idAllocator == plan.idAllocator)
    }

    @Test func moveKeepsChordIdentityThroughUndoRedo() throws {
        let editor = ScoreEditor(score: Fixture.score([[source, Voice(elements: [.rest(duration: .measure)])]]))
        let before = editor.score
        let initial = editor.idAllocator
        let old = Fixture.ids(Fixture.elements(before))
        let destinationID = Fixture.elements(before, voice: 1).eid(at: 0)
        // A fresh destination chord would be N4 here (the source rest mints N3 first), with counter n + 4.
        try editor.apply(move)
        #expect(Fixture.ids(Fixture.elements(editor.score)) == [old[0], Fixture.minted(initial, 3), old[2]])
        #expect(Fixture.ids(Fixture.elements(editor.score, voice: 1)) == [
            destinationID, old[1], Fixture.minted(initial, 2),
        ])
        #expect(Fixture.elements(editor.score).values == [
            .rest(duration: .quarter), .rest(duration: .quarter), .rest(duration: .half),
        ])
        #expect(Fixture.elements(editor.score, voice: 1).values == source.elements.values)
        let sourceHasChordID = Fixture.ids(Fixture.elements(editor.score)).contains(old[1])
        #expect(!sourceHasChordID)
        #expect(editor.idAllocator == Fixture.advanced(initial, by: 3))
        let applied = editor.score
        let appliedIDs = Set(Fixture.allIDs(applied))
        try editor.undo()
        Fixture.expectSameScore(editor.score, before)
        #expect(Set(Fixture.allIDs(editor.score)) == Set(Fixture.allIDs(before)))
        try editor.redo()
        Fixture.expectSameScore(editor.score, applied)
        #expect(Set(Fixture.allIDs(editor.score)) == appliedIDs)
        #expect(editor.idAllocator == Fixture.advanced(initial, by: 3))
    }
}
