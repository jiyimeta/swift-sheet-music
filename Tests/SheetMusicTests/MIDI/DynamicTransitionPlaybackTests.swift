@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

/// MuseScore 4 plays fp, sfp (f to p), sfpp (f to pp) and pf (p to f) as a change between two levels: the first on the
/// dynamic's own chord, six linear steps over `velocityChangeLength` — 0.4 s, 0.65 s slow, 0.25 s fast, at any tempo —
/// and the second from then on (`PlaybackContext::updateDynamicMap`, `engraving/playback/playbackcontext.cpp:410-427`;
/// `dom/dynamic.cpp:174-196`). A crescendo starting on one starts once the change is done (`:576-593`); one ending on
/// one aims for its first level (`:136-139`) (import fidelity F4.4).
@Suite("Two-level dynamics in playback")
struct DynamicTransitionPlaybackTests {
    private typealias F = DynamicPlaybackFixtures

    @Test("fp plays f on its chord and p from 0.4 s on")
    func fpFallsToPiano() throws {
        let bar = [F.dynamic("fp"), F.quarter, F.quarter, F.quarter, F.quarter]
        #expect(try F.velocities(F.score([bar])) == [96, 49, 49, 49])
    }

    @Test("a note inside the change takes its step")
    func notesInsideTheChangeTakeItsSteps() throws {
        let bar = [F.dynamic("fp")] + Array(repeating: F.eighth, count: 8)
        #expect(try F.velocities(F.score([bar])) == [96, 73, 49, 49, 49, 49, 49, 49])
    }

    @Test("a slow change takes 1.3 quarters at 120: its steps reach further")
    func slowSpeedStretchesTheSteps() throws {
        let bar = [F.dynamic("sfp", speed: .slow)] + Array(repeating: F.eighth, count: 8)
        #expect(try F.velocities(F.score([bar])) == [96, 81, 65, 49, 49, 49, 49, 49])
    }

    @Test("the tempo where it stands scales it: at ♩ = 60 the change is over by the second eighth")
    func theTempoWhereItStandsScalesIt() throws {
        let bar = [F.dynamic("fp")] + Array(repeating: F.eighth, count: 8)
        #expect(try F.velocities(F.score([bar], tempo: 1)) == [96, 49, 49, 49, 49, 49, 49, 49])
    }

    @Test("sfpp falls from f to pp; pf rises from p to f")
    func otherTwoLevelDynamics() throws {
        let score = F.score([
            [F.dynamic("sfpp"), F.quarter, F.quarter, F.quarter, F.quarter],
            [F.dynamic("pf"), F.quarter, F.quarter, F.quarter, F.quarter],
        ])
        #expect(try F.velocities(score) == [96, 33, 33, 33, 49, 96, 96, 96])
    }

    @Test("a crescendo starting on a two-level dynamic starts once the change is done, from its second level")
    func crescendoFromATwoLevelDynamic() throws {
        let score = F.score([
            [F.dynamic("fp"), F.crescendo(), F.quarter, F.quarter, F.quarter, F.quarter],
            [F.dynamic("f"), F.quarter, F.quarter, F.quarter, F.quarter],
        ])
        #expect(try F.velocities(score) == [96, 52, 67, 81, 96, 96, 96, 96])
    }

    @Test("a crescendo ending on a two-level dynamic aims for its first level, and the second follows")
    func crescendoToATwoLevelDynamic() throws {
        let score = F.score([
            [F.dynamic("p"), F.crescendo(), F.quarter, F.quarter, F.quarter, F.quarter],
            [F.dynamic("sfpp"), F.quarter, F.quarter, F.quarter, F.quarter],
        ])
        #expect(try F.velocities(score) == [49, 61, 73, 84, 96, 33, 33, 33])
    }

    @Test("the dynamics fixture plays as MuseScore 4 plays it, bar by bar")
    func fixturePlaysAsMuseScore4() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("dynamics"))
        #expect(try F.velocities(score) == [
            49, 49, 49, 49, 49, 49, 49, 49, 96, 96, 96, 96, 96, 96, 96, 96, 96, 96, 96, 96,
            80, 80, 112, 80, 96, 49, 49, 49, 96, 81, 65, 49, 49, 49, 49, 49, 1, 1, 1, 1,
        ])
    }

    @Test("the roles, the change's length and its steps")
    func rolesLengthAndSteps() {
        #expect(Dynamic(subtype: "fp", velocity: 96).playbackRole == .transition(from: 96, to: 49))
        #expect(Dynamic(subtype: "sfpp", velocity: 112).playbackRole == .transition(from: 96, to: 33))
        #expect(Dynamic(subtype: "pf", velocity: 49).playbackRole == .transition(from: 49, to: 96))
        let fp = Dynamic(subtype: "fp", velocity: 96)
        #expect(fp.velocityChangeTicks(beatsPerSecond: 2, division: 480) == 384)
        #expect(fp.velocityChangeTicks(beatsPerSecond: 1, division: 480) == 192)
        let fast = Dynamic(subtype: "fp", velocity: 96, velocityChangeSpeed: .fast)
        #expect(fast.velocityChangeTicks(beatsPerSecond: 2, division: 480) == 240)
        let steps = Dynamic.transitionSteps(from: 96, to: 49, ticks: 384)
        #expect(steps.map(\.offset) == [0, 64, 128, 192, 256, 320, 384])
        #expect(steps.map(\.velocity) == [96, 89, 81, 73, 65, 57, 49])
    }
}
