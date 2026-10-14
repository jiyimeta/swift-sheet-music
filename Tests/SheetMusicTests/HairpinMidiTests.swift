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
        // The reference is MuseScore's MIDI *export*, and this library
        // deliberately differs from it: non-linear curve methods (.easeIn /
        // .easeOut / .easeInOut / .exponential) still fall through to
        // linear interpolation, and dynamics play as MuseScore 4's
        // *playback* plays them (import-fidelity owner decision c) — a
        // hairpin aims where MuseScore 4 aims it, and fp / sfp / sfpp are a
        // two-level change from f, not the export's running velocity.
        // Tracked via withKnownIssue so the test still runs and starts
        // failing loudly if the two ever agree.
        withKnownIssue("non-linear curve methods; dynamics follow MuseScore 4 playback, not its export") {
            try MidiSemanticComparison.assertEquivalent(
                produced: produced,
                reference: reference,
                options: .init(ignoreControlChange: true),
            )
        }
    }
}
