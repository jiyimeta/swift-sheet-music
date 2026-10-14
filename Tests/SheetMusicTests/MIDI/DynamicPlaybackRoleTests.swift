@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// What a dynamic does to playback is read in one place, `Dynamic.playbackRole`, by the SMF's voice walk and by
/// `HairpinRamps`. An ordinary dynamic is a running level at its stored velocity — MuseScore's or the file's — from its
/// own chord to the next dynamic (spec 2026-10-14 §7.3).
@Suite("Dynamic playback role")
struct DynamicPlaybackRoleTests {
    private typealias F = DynamicPlaybackFixtures

    @Test("an ordinary dynamic is a running level at its stored velocity")
    func ordinaryIsALevel() {
        #expect(Dynamic(subtype: "mp", velocity: 70).playbackRole == .level(velocity: 70))
        let ff = Dynamic(subtype: "ff", velocity: Dynamic.defaultVelocity(for: "ff"))
        #expect(ff.playbackRole == .level(velocity: 112))
    }

    @Test("a level holds from its own chord to the next dynamic")
    func levelHoldsUntilTheNextDynamic() throws {
        let bar = [F.dynamic("p"), F.quarter, F.dynamic("mf"), F.quarter, F.quarter, F.quarter]
        #expect(try F.velocities(F.score([bar])) == [49, 80, 80, 80])
    }
}
