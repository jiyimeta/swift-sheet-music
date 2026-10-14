@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// MuseScore 4 plays sf, sfz, rf, rfz (at f), sff, sffz (ff), sfff, sfffz (fff) as accents: the chord on their tick
/// takes the level, and the level the dynamics had put in force before it comes back with the next
/// (`PlaybackContext::updateDynamicMap`, `engraving/playback/playbackcontext.cpp:397-408`;
/// `playback/utils/expressionutils.h:67-76`) — read before any hairpin is laid out (`:324-339`), so never a hairpin's
/// held level. A crescendo starting on one starts from it (`:600-601`); one ending on one aims for it (`:124-142`)
/// (import fidelity F4.4).
@Suite("Accent dynamics in playback")
struct DynamicAccentPlaybackTests {
    private typealias F = DynamicPlaybackFixtures

    @Test("an accent plays its level on its own chord only", arguments: [
        ("sf", 96), ("sfz", 96), ("rf", 96), ("rfz", 96), ("sff", 112), ("sffz", 112), ("sfff", 126), ("sfffz", 126),
    ] as [(String, Int)])
    func accentPlaysItsLevelOnItsChordOnly(subtype: String, level: Int) throws {
        let bar = [F.dynamic("p"), F.quarter, F.dynamic(subtype), F.quarter, F.quarter, F.quarter]
        #expect(try F.velocities(F.score([bar])) == [49, level, 49, 49])
    }

    @Test("an accent lasts its whole chord, however long")
    func accentLastsItsChord() throws {
        let bar = [F.dynamic("p"), F.quarter, F.dynamic("sf"), F.half, F.quarter]
        #expect(try F.velocities(F.score([bar])) == [49, 96, 49])
    }

    @Test("a crescendo starting on an accent starts from its level")
    func crescendoFromAnAccent() throws {
        let score = F.score([
            [F.dynamic("p"), F.quarter, F.quarter, F.quarter, F.quarter],
            [F.dynamic("sf"), F.crescendo(), F.quarter, F.quarter, F.quarter, F.quarter],
            [F.dynamic("ff"), F.quarter, F.quarter, F.quarter, F.quarter],
        ])
        #expect(try F.velocities(score) == [49, 49, 49, 49, 96, 100, 104, 108, 112, 112, 112, 112])
    }

    @Test("a crescendo ending on an accent climbs to its level; the level before the crescendo comes back after it")
    func crescendoToAnAccent() throws {
        let score = F.score([
            [F.dynamic("p"), F.crescendo(), F.quarter, F.quarter, F.quarter, F.quarter],
            [F.dynamic("sf"), F.quarter, F.quarter, F.quarter, F.quarter],
        ])
        #expect(try F.velocities(score) == [49, 61, 73, 84, 96, 49, 49, 49])
    }

    @Test("an accent in a hairpin's held level sounds, then the level before the hairpin comes back")
    func accentAfterAHairpinDropsToTheLevelBeforeIt() throws {
        let score = F.score([
            [F.dynamic("p"), F.crescendo(), F.quarter, F.quarter, F.quarter, F.quarter],
            [F.quarter, F.dynamic("sf"), F.quarter, F.quarter, F.quarter],
        ])
        #expect(try F.velocities(score) == [49, 53, 57, 60, 64, 96, 49, 49])
    }

    @Test("an accent inside a crescendo sounds on its chord, and the crescendo carries on")
    func accentInsideACrescendoLeavesItGoing() throws {
        let score = F.score([
            [F.dynamic("p"), F.crescendo(), F.quarter, F.dynamic("sf"), F.quarter, F.quarter, F.quarter],
            [F.dynamic("f"), F.quarter, F.quarter, F.quarter, F.quarter],
        ])
        #expect(try F.velocities(score) == [49, 96, 73, 84, 96, 96, 96, 96])
    }

    @Test("the roles, by MuseScore 4's single-note table")
    func roles() {
        #expect(Dynamic(subtype: "sf", velocity: 112).playbackRole == .accent(velocity: 96))
        #expect(Dynamic(subtype: "sffz", velocity: 126).playbackRole == .accent(velocity: 112))
        #expect(Dynamic(subtype: "sfffz", velocity: 127).playbackRole == .accent(velocity: 126))
        #expect(Dynamic(subtype: "sf", velocity: 112, playsBack: false).playbackRole == .none)
    }
}
