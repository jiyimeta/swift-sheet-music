import Foundation
@testable import SheetMusicCore
import Testing

@Suite("CrossBarInputPlanner (direct)")
struct CrossBarInputPlannerTests {
    /// A half note armed at the last quarter of a 4/4 bar does not fit — the planner must answer with a plan
    /// rather than nil, because the alternative (letting SetRestDuration refuse) takes the note write down too.
    @Test func `a duration that overruns the barline produces a plan`() {
        let score = EditingFixtures.twoMeasuresOfQuarterRests()
        let last = VoiceElementID(EditingFixtures.restID(element: 4))
        #expect(!CrossBarInputPlanner.fitsInMeasure(.half, at: last, in: score))
        #expect(CrossBarInputPlanner.plan(.rest, duration: .half, at: last, in: score) != nil)
    }

    @Test func `a duration that fits needs no plan`() {
        let score = EditingFixtures.twoMeasuresOfQuarterRests()
        let first = VoiceElementID(EditingFixtures.restID(element: 2))
        #expect(CrossBarInputPlanner.fitsInMeasure(.quarter, at: first, in: score))
        #expect(CrossBarInputPlanner.plan(.rest, duration: .quarter, at: first, in: score) == nil)
    }
}
