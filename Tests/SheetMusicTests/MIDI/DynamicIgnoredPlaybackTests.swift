@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// The dynamics MuseScore 4's playback does not play change nothing — fz, m, r, s, z, `other-dynamics`, a token it
/// does not know, and any dynamic with `<play>0</play>` (`PlaybackContext::updateDynamicMap`,
/// `engraving/playback/playbackcontext.cpp:386-428`) — and niente is its softest ordinary level
/// (`playback/utils/expressionutils.h:34`) (import fidelity F4.2–F4.4).
@Suite("Dynamics MuseScore 4 does not play")
struct DynamicIgnoredPlaybackTests {
    private typealias F = DynamicPlaybackFixtures

    @Test("an ignored dynamic leaves the level where it was", arguments: [
        "fz", "m", "r", "s", "z", "other-dynamics", "sfzp",
    ])
    func ignoredSubtypesLeaveTheLevel(subtype: String) throws {
        let bar = [F.dynamic("p"), F.quarter, F.dynamic(subtype), F.quarter, F.quarter, F.quarter]
        #expect(try F.velocities(F.score([bar])) == [49, 49, 49, 49])
    }

    @Test("a dynamic that does not play changes nothing")
    func mutedDynamicChangesNothing() throws {
        let bar = [
            F.dynamic("p"), F.quarter, F.dynamic("ff", playsBack: false), F.quarter, F.quarter, F.quarter,
        ]
        #expect(try F.velocities(F.score([bar])) == [49, 49, 49, 49])
    }

    @Test("niente is the softest level there is")
    func nienteIsTheSoftestLevel() throws {
        let bar = [F.dynamic("p"), F.quarter, F.dynamic("n"), F.quarter, F.quarter, F.quarter]
        #expect(try F.velocities(F.score([bar])) == [49, 1, 1, 1])
    }

    @Test("a diminuendo to niente fades to it")
    func diminuendoToNiente() throws {
        let score = F.score([
            [F.dynamic("p"), F.diminuendo(), F.quarter, F.quarter, F.quarter, F.quarter],
            [F.dynamic("n"), F.quarter, F.quarter, F.quarter, F.quarter],
        ])
        #expect(try F.velocities(score) == [49, 37, 25, 13, 1, 1, 1, 1])
    }

    @Test("a crescendo does not aim at a dynamic that does not play")
    func crescendoIgnoresAnIgnoredMark() throws {
        let score = F.score([
            [F.dynamic("p"), F.crescendo(), F.quarter, F.quarter, F.quarter, F.quarter],
            [F.dynamic("fz"), F.quarter, F.quarter, F.quarter, F.quarter],
        ])
        #expect(try F.velocities(score) == [49, 49, 49, 49, 49, 49, 49, 49])
    }

    @Test("the roles, by MuseScore 4's tables")
    func roles() {
        #expect(Dynamic(subtype: "fz", velocity: 112).playbackRole == .none)
        #expect(Dynamic(subtype: "other-dynamics", velocity: 80).playbackRole == .none)
        #expect(Dynamic(subtype: "ff", velocity: 112, playsBack: false).playbackRole == .none)
        #expect(Dynamic(subtype: "n", velocity: 49).playbackRole == .level(velocity: 1))
        #expect(Dynamic(subtype: "pppppp", velocity: 1).playbackRole == .level(velocity: 1))
    }
}
