@testable import SheetMusicCore
import Testing

@Suite("Measure rest collapse identity classification")
struct RestCollapseIdentityTests {
    private typealias Fixture = VoiceIdentityFixtures

    @Test func collapseKeepsSurvivingOnsetRest() throws {
        let editor = ScoreEditor(score: Fixture.score(elements: [
            Fixture.time, .rest(duration: .half), Fixture.chord(.half),
        ]))
        let before = editor.score
        let initial = editor.idAllocator
        let old = Fixture.ids(Fixture.elements(before))
        let plan = try #require(FullMeasureRestCollapse.plan(deleting: Fixture.location(2), in: before))
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
        let plan = try #require(FullMeasureRestCollapse.plan(deleting: Fixture.location(1), in: before))
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
}
