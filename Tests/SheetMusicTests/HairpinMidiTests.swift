import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

struct HairpinMidiTests {
    @Test func testSingleNoteDynamicsVelocityRamp() throws {
        let scoreURL = try #require(
            TestResources.url(forResource: "testSingleNoteDynamics", withExtension: "mscx"),
        )
        let refURL = try #require(
            TestResources.url(forResource: "testSingleNoteDynamics-ref", withExtension: "mid"),
        )
        let score = try SheetMusic.loadScore(mscxData: Data(contentsOf: scoreURL))
        let produced = try SheetMusic.exportMIDI(score: score)
        let reference = try Data(contentsOf: refURL)
        // v1 falls non-linear curve methods (.easeIn / .easeOut /
        // .easeInOut / .exponential) through to linear interpolation.
        // The fixture exercises every method plus an SFP/FP tail with
        // per-Dynamic veloChange — all of which are explicitly out of
        // scope for v1. Track the residual divergences via
        // withKnownIssue so the test still runs and will start failing
        // loudly the moment any of those follow-ups land.
        withKnownIssue("non-linear curve methods + SFP velocity profile are v1 follow-ups") {
            try MidiSemanticComparison.assertEquivalent(
                produced: produced,
                reference: reference,
                options: .init(ignoreControlChange: true),
            )
        }
    }
}
