@testable import SheetMusicCore
import Testing

@Suite("Measure rest collapse identity classification")
struct RestCollapseIdentityTests {
    private typealias Fixture = VoiceIdentityFixtures

    private static var voice: VoiceRef {
        VoiceRef(Fixture.location(0))
    }

    @Test func collapseKeepsSurvivingOnsetRest() throws {
        let editor = ScoreEditor(score: Fixture.score(elements: [
            Fixture.time, .rest(duration: .half), Fixture.chord(.half),
        ]))
        let before = editor.score
        let initial = editor.idAllocator
        let old = Fixture.ids(Fixture.elements(before))
        let plan = try #require(FullMeasureRestCollapse.plan(clearing: [1, 2], in: Self.voice, of: before))
        #expect(plan.restElementIndex == 1)
        #expect(plan.command.slots == [
            VoiceSlot(identity: .keep(old[0]), element: Fixture.time),
            VoiceSlot(identity: .keep(old[1]), element: .rest(duration: .measure)),
        ])
        Fixture.expectSameScore(editor.score, before)
        #expect(editor.idAllocator == initial)
        try editor.apply(plan.command)
        #expect(Fixture.ids(Fixture.elements(editor.score)) == [old[0], old[1]])
        #expect(Fixture.elements(editor.score).values == [Fixture.time, .rest(duration: .measure)])
        #expect(editor.idAllocator == initial)
        try editor.undo()
        Fixture.expectSameScore(editor.score, before)
    }

    @Test func collapseReplacesDeletedOnsetChord() throws {
        let editor = ScoreEditor(score: Fixture.score(elements: [
            Fixture.time, Fixture.chord(.half), .rest(duration: .half),
        ]))
        let before = editor.score
        let initial = editor.idAllocator
        let old = Fixture.ids(Fixture.elements(before))
        let plan = try #require(FullMeasureRestCollapse.plan(clearing: [1, 2], in: Self.voice, of: before))
        #expect(plan.restElementIndex == 1)
        #expect(plan.command.slots == [
            VoiceSlot(identity: .keep(old[0]), element: Fixture.time),
            VoiceSlot(identity: .fresh, element: .rest(duration: .measure)),
        ])
        Fixture.expectSameScore(editor.score, before)
        #expect(editor.idAllocator == initial)
        try editor.apply(plan.command)
        #expect(Fixture.ids(Fixture.elements(editor.score)) == [old[0], Fixture.minted(initial, 1)])
        #expect(Fixture.elements(editor.score).values == [Fixture.time, .rest(duration: .measure)])
        #expect(editor.idAllocator == Fixture.advanced(initial, by: 1))
        try editor.undo()
        Fixture.expectSameScore(editor.score, before)
    }

    /// The rule the collapse is gated on: coverage, not what survives. A rest the caller is not clearing is a rest
    /// it may not swallow, so neither of these partial clears plans a collapse — the bar keeps its two half slots.
    @Test func partialCoverageDoesNotCollapse() {
        let withTrailingRest = Fixture.score(elements: [Fixture.time, Fixture.chord(.half), .rest(duration: .half)])
        #expect(FullMeasureRestCollapse.plan(clearing: [1], in: Self.voice, of: withTrailingRest) == nil)
        let withLeadingRest = Fixture.score(elements: [Fixture.time, .rest(duration: .half), Fixture.chord(.half)])
        #expect(FullMeasureRestCollapse.plan(clearing: [2], in: Self.voice, of: withLeadingRest) == nil)
    }
}
