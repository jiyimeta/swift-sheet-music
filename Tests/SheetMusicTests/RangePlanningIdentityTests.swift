@testable import SheetMusicCore
import Testing

@Suite("Range planning identity replay")
struct RangePlanningIdentityTests {
    private typealias Fixture = VoiceIdentityFixtures

    @Test func rangePlannerReplaysMintedIdentifiers() throws {
        let editor = ScoreEditor(score: Fixture.score(elements: [Fixture.chord(.half), Fixture.chord(.half)]))
        let before = editor.score
        let initial = editor.idAllocator
        let old = Fixture.ids(Fixture.elements(before))
        let range = VoiceElementRange(start: Fixture.location(0), end: Fixture.location(0))
        let planned = try RangeEditPlanner.plan(over: range, in: before, ids: initial) { target, _ in
            [DeleteVoiceElement(at: target)]
        }
        let plan = try #require(planned)
        let expected = [Fixture.minted(initial, 1), old[1]]
        #expect(plan.commands.count == 1)
        #expect(Fixture.ids(Fixture.elements(plan.result)) == expected)
        #expect(Fixture.elements(plan.result).values == [.rest(duration: .half), Fixture.chord(.half)])
        #expect(plan.idAllocator == Fixture.advanced(initial, by: 1))
        Fixture.expectSameScore(editor.score, before)
        #expect(editor.idAllocator == initial)
        try editor.apply(plan.composite)
        Fixture.expectSameScore(editor.score, plan.result)
        #expect(editor.idAllocator == plan.idAllocator)
    }

    @Test func durationRangeReplaysSplitIdentifiers() throws {
        let editor = ScoreEditor(score: Fixture.score(elements: Array(repeating: Fixture.chord(), count: 4)))
        let before = editor.score
        let initial = editor.idAllocator
        let old = Fixture.ids(Fixture.elements(before))
        let range = VoiceElementRange(start: Fixture.location(0), end: Fixture.location(3))
        let planned = try RangeEditPlanner.plan(over: range, in: before, ids: initial) { target, _ in
            [SetChordDuration(at: target, duration: .eighth)]
        }
        let plan = try #require(planned)
        let expected = [
            old[0], Fixture.minted(initial, 1), old[1], Fixture.minted(initial, 2),
            old[2], Fixture.minted(initial, 3), old[3], Fixture.minted(initial, 4),
        ]
        let expectedValues = Array(repeating: [Fixture.chord(.eighth), .rest(duration: .eighth)], count: 4)
            .flatMap(\.self)
        #expect(plan.commands.count == 4)
        #expect(Fixture.ids(Fixture.elements(plan.result)) == expected)
        #expect(Fixture.elements(plan.result).values == expectedValues)
        #expect(plan.idAllocator == Fixture.advanced(initial, by: 4))
        Fixture.expectSameScore(editor.score, before)
        #expect(editor.idAllocator == initial)
        try editor.apply(SetDurationInRange(over: range, duration: .eighth))
        Fixture.expectSameScore(editor.score, plan.result)
        #expect(editor.idAllocator == plan.idAllocator)
    }

    @Test func deleteRangeCollapseKeepsScratchMintedRest() throws {
        let editor = ScoreEditor(score: Fixture.score(elements: [Fixture.chord(.half), Fixture.chord(.half)]))
        let before = editor.score
        let initial = editor.idAllocator
        let range = VoiceElementRange(start: Fixture.location(0), end: Fixture.location(1))
        let command = DeleteRange(over: range)
        let planned = try command.detailedPlan(in: before, ids: initial)
        let plan = try #require(planned)
        #expect(plan.commands.count == 3)
        let collapse = try #require(plan.commands.last as? ReplaceVoiceElements)
        #expect(collapse.slots == [VoiceSlot(
            identity: .keep(Fixture.minted(initial, 1)), element: .rest(duration: .measure),
        )])
        #expect(Fixture.ids(Fixture.elements(plan.result)) == [Fixture.minted(initial, 1)])
        #expect(Fixture.elements(plan.result).values == [.rest(duration: .measure)])
        #expect(plan.idAllocator == Fixture.advanced(initial, by: 2))
        Fixture.expectSameScore(editor.score, before)
        #expect(editor.idAllocator == initial)
        try editor.apply(command)
        Fixture.expectSameScore(editor.score, plan.result)
        #expect(editor.idAllocator == plan.idAllocator)
        try editor.undo()
        Fixture.expectSameScore(editor.score, before)
        try editor.redo()
        Fixture.expectSameScore(editor.score, plan.result)
        #expect(editor.idAllocator == plan.idAllocator)
    }
}
