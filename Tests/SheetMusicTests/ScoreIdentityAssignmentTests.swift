import SheetMusicCore
import Testing

@Suite("Score identity assignment")
struct ScoreIdentityAssignmentTests {
    @Test func twoMintsUseDistinctCounters() throws {
        var score = Score(division: 480)
        var ids = EIDAllocator(actor: 42, counter: 10)
        try MintIDs().apply(to: &score, ids: &ids)
        let minted = MintIDs.recorded(in: score)
        #expect(minted == [EID(first: 42, second: 11), EID(first: 42, second: 12)])
        #expect(minted[0] != minted[1])
        #expect(ids.counter == 12)
    }

    @Test func successiveEditsContinueTheAllocator() throws {
        let editor = ScoreEditor(score: Score(division: 480))
        let initial = editor.idAllocator
        try editor.apply(MintIDs())
        let first = MintIDs.recorded(in: editor.score)
        try editor.apply(MintIDs())
        let second = MintIDs.recorded(in: editor.score)
        #expect(first == [EID(first: initial.actor, second: 1), EID(first: initial.actor, second: 2)])
        #expect(second == [EID(first: initial.actor, second: 3), EID(first: initial.actor, second: 4)])
        #expect(Set(first + second).count == 4)
        #expect(editor.idAllocator == EIDAllocator(actor: initial.actor, counter: 4))
    }

    @Test func undoAndRedoAdvanceWithoutRollingBack() throws {
        let original = Score(division: 480)
        let editor = ScoreEditor(score: original)
        let actor = editor.idAllocator.actor
        try editor.apply(MintIDs())
        let edited = editor.score
        try editor.undo()
        #expect(editor.score == original)
        #expect(editor.idAllocator == EIDAllocator(actor: actor, counter: 4))
        try editor.redo()
        #expect(editor.score == edited)
        #expect(editor.idAllocator == EIDAllocator(actor: actor, counter: 6))
    }

    @Test func compositeSharesOneAllocator() throws {
        let editor = ScoreEditor(score: Score(division: 480))
        let command = MintIDs()
        try editor.apply(CompositeEditCommand(commands: [command, command], location: command.affectedLocation))
        #expect(MintIDs.recorded(in: editor.score) == [
            EID(first: editor.idAllocator.actor, second: 3), EID(first: editor.idAllocator.actor, second: 4),
        ])
        #expect(editor.idAllocator.counter == 4)
    }

    @Test func bareScoreConvenienceForwards() throws {
        var score = Score(division: 480)
        try MintIDs().apply(to: &score)
        let minted = MintIDs.recorded(in: score)
        // Evaluated outside the macro: `#expect` rewrites a function call into
        // `__checkFunctionCall`, which cannot prove `allSatisfy`'s rethrows away.
        let allValid = minted.allSatisfy(\.isValid)
        #expect(minted.count == 2)
        #expect(allValid)
        #expect(minted.map(\.second) == [1, 2])
    }
}

/// Records forward mints in score metadata; inverses mint too, then restore the captured metadata.
private struct MintIDs: EditCommand {
    var restoredTags: [String: String]?

    var affectedLocation: VoiceElementID {
        VoiceElementID(
            staff: StaffAddress(partIndex: 0, staffIndexInPart: 0),
            measureIndex: 0, voiceIndex: 0, elementIndex: 0,
        )
    }

    @discardableResult
    func apply(to score: inout Score, ids: inout EIDAllocator) throws -> any EditCommand {
        let minted = [ids.next(), ids.next()]
        let original = score.metaTags
        score.metaTags = restoredTags ?? ["minted": minted.map(\.stringValue).joined(separator: ",")]
        return MintIDs(restoredTags: original)
    }

    static func recorded(in score: Score) -> [EID] {
        (score.metaTags["minted"] ?? "").split(separator: ",").compactMap { EID(string: String($0)) }
    }
}
