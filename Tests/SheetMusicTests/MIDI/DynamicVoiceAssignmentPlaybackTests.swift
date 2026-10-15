@testable import SheetMusicCore
@testable import SheetMusicMIDI
@testable import SheetMusicMSCX
import Testing

/// MuseScore 4 lays a dynamic and a hairpin into every voice its `<voiceAssignment>` reaches — the whole instrument by
/// default, so both hands of a piano — and on one tick of one voice the narrower assignment wins
/// (`PlaybackContext::applyDynamic`, `engraving/playback/playbackcontext.cpp:805-837`) (owner decision c).
@Suite("Dynamics across an instrument's staves and voices")
struct DynamicVoiceAssignmentPlaybackTests {
    private typealias F = DynamicPlaybackFixtures
    private static let low = 48

    private static func lowBar(_ durations: [NoteDuration] = [.quarter, .quarter, .quarter, .quarter])
        -> [VoiceElement]
    {
        durations.map { F.note($0, pitch: low) }
    }

    @Test("a dynamic in the upper staff plays in the lower one")
    func upperDynamicReachesTheLowerStaff() throws {
        let score = F.grandStaff(
            upper: [[[F.dynamic("p"), F.quarter, F.quarter, F.quarter, F.quarter]]],
            lower: [[Self.lowBar()]],
        )
        #expect(try F.velocities(score, track: 0) == [49, 49, 49, 49])
        #expect(try F.velocities(score, track: 1) == [49, 49, 49, 49])
    }

    @Test("a dynamic for its staff stays in its staff")
    func anAllInStaffDynamicStaysInItsStaff() throws {
        let score = F.grandStaff(
            upper: [
                [[F.dynamic("p"), F.quarter, F.quarter, F.quarter, F.quarter]],
                [[F.dynamic("f", assignment: .allInStaff), F.quarter, F.quarter, F.quarter, F.quarter]],
            ],
            lower: [[Self.lowBar()], [Self.lowBar()]],
        )
        #expect(try F.velocities(score, track: 0) == [49, 49, 49, 49, 96, 96, 96, 96])
        #expect(try F.velocities(score, track: 1) == [49, 49, 49, 49, 49, 49, 49, 49])
    }

    @Test("a dynamic for its own voice stays in its voice")
    func aCurrentVoiceOnlyDynamicStaysInItsVoice() throws {
        let alto = [F.note(.half, pitch: 64), F.note(.half, pitch: 64)]
        let score = F.grandStaff(
            upper: [
                [[F.dynamic("p"), F.quarter, F.quarter, F.quarter, F.quarter], alto],
                [[F.quarter, F.quarter, F.quarter, F.quarter], [F.dynamic("pp", assignment: .currentVoiceOnly)] + alto],
            ],
            lower: [[Self.lowBar()], [Self.lowBar()]],
        )
        #expect(try F.velocities(score, track: 0, pitch: 60) == [49, 49, 49, 49, 49, 49, 49, 49])
        #expect(try F.velocities(score, track: 0, pitch: 64) == [49, 49, 33, 33])
        #expect(try F.velocities(score, track: 1) == [49, 49, 49, 49, 49, 49, 49, 49])
    }

    /// Passes before this task too — no dynamic reached past its own voice then. It pins that MuseScore's priority, not
    /// file order, decides a tick: the lower staff's f comes later in the file and still loses the upper voice's tick.
    @Test("on one tick of one voice the narrower assignment wins")
    func theNarrowerAssignmentWinsATick() throws {
        let score = F.grandStaff(
            upper: [[[F.dynamic("p", assignment: .currentVoiceOnly), F.quarter, F.quarter, F.quarter, F.quarter]]],
            lower: [[[F.dynamic("f")] + Self.lowBar()]],
        )
        #expect(try F.velocities(score, track: 0) == [49, 49, 49, 49])
        #expect(try F.velocities(score, track: 1) == [96, 96, 96, 96])
    }

    @Test("a hairpin in the upper staff swells the lower one")
    func aHairpinReachesTheOtherStaff() throws {
        let score = F.grandStaff(
            upper: [
                [[F.dynamic("p"), F.crescendo(), F.quarter, F.quarter, F.quarter, F.quarter]],
                [[F.dynamic("f"), F.quarter, F.quarter, F.quarter, F.quarter]],
            ],
            lower: [[Self.lowBar()], [Self.lowBar()]],
        )
        #expect(try F.velocities(score, track: 1) == [49, 61, 73, 84, 96, 96, 96, 96])
    }

    /// MuseScore resolves a hairpin once, on its own track, and lays that curve into every track it reaches
    /// (`handleHairpin`, `playbackcontext.cpp:569-647`): a closing f written in the other staff is no end it aims for
    /// (`HairpinSegment::findEndDynamicOrExpression` reads its own track) — it climbs one level, p to mp (64), stopping
    /// a tick short of the f, which governs its own note in both staves.
    @Test("a hairpin aims only for an end dynamic in its own staff and voice")
    func aHairpinAimsOnlyForItsOwnEndDynamic() throws {
        let score = F.grandStaff(
            upper: [
                [[F.dynamic("p"), F.crescendo(), F.quarter, F.quarter, F.quarter, F.quarter]],
                [[F.quarter, F.quarter, F.quarter, F.quarter]],
            ],
            lower: [[Self.lowBar()], [[F.dynamic("f")] + Self.lowBar()]],
        )
        #expect(try F.velocities(score, track: 0) == [49, 53, 57, 60, 96, 96, 96, 96])
        #expect(try F.velocities(score, track: 1) == [49, 53, 57, 60, 96, 96, 96, 96])
    }

    /// A two-level dynamic delays a hairpin only when it stands in the hairpin's own track (`handleHairpin` reads the
    /// start segment's dynamic of that track, `playbackcontext.cpp:576-593`); written in the other staff, the hairpin
    /// starts on its tick from the change's first level, f, and climbs one level to ff (112).
    @Test("a hairpin waits for a two-level change only when the change is written in its own staff and voice")
    func aTransitionElsewhereDoesNotDelayAHairpin() throws {
        let score = F.grandStaff(
            upper: [
                [[F.crescendo(), F.quarter, F.quarter, F.quarter, F.quarter]],
                [[F.quarter, F.quarter, F.quarter, F.quarter]],
            ],
            lower: [[[F.dynamic("fp")] + Self.lowBar()], [Self.lowBar()]],
        )
        #expect(try F.velocities(score, track: 0) == [96, 100, 104, 108, 112, 112, 112, 112])
    }

    /// Of an accent and a narrower level on one tick, the level takes the tick (`applyDynamic`'s priority,
    /// `playbackcontext.cpp:831-835`) — the accent's chord plays no accent there. With mf the level coming back after
    /// the accent is the one in force anyway.
    @Test("a narrower level on an accent's tick takes the chord from it")
    func aNarrowerLevelOverrulesAnAccent() throws {
        let score = F.grandStaff(
            upper: [[[F.dynamic("sf"), F.quarter, F.quarter, F.quarter, F.quarter]]],
            lower: [[[F.dynamic("mf", assignment: .currentVoiceOnly)] + Self.lowBar()]],
        )
        #expect(try F.velocities(score, track: 0) == [96, 80, 80, 80])
        #expect(try F.velocities(score, track: 1) == [80, 80, 80, 80])
    }

    /// A narrower level on a two-level dynamic's tick overrules the change's first step only: its later steps still
    /// follow and land on its second level (`updateDynamicMap`, `playbackcontext.cpp:410-427`) — mf on the tick, then
    /// p.
    @Test("a narrower level on a two-level dynamic's tick takes the tick, and the change goes on after it")
    func aNarrowerLevelOverrulesATransitionsFirstStep() throws {
        let score = F.grandStaff(
            upper: [[[F.dynamic("fp"), F.quarter, F.quarter, F.quarter, F.quarter]]],
            lower: [[[F.dynamic("mf", assignment: .currentVoiceOnly)] + Self.lowBar()]],
        )
        #expect(try F.velocities(score, track: 0) == [96, 49, 49, 49])
        #expect(try F.velocities(score, track: 1) == [80, 49, 49, 49])
    }

    @Test("an accent reaches the chords that start with it, not one sounding across it")
    func anAccentReachesChordsStartingWithIt() throws {
        let bar = [F.dynamic("p"), F.quarter, F.dynamic("sf"), F.quarter, F.quarter, F.quarter]
        let upper: [[[VoiceElement]]] = [[bar]]
        let starting = F.grandStaff(upper: upper, lower: [[Self.lowBar([.quarter, .quarter, .half])]])
        #expect(try F.velocities(starting, track: 1) == [49, 96, 49])
        let sounding = F.grandStaff(upper: upper, lower: [[Self.lowBar([.half, .half])]])
        #expect(try F.velocities(sounding, track: 1) == [49, 49])
    }

    @Test("the voices fixture plays as MuseScore 4 plays it")
    func fixturePlaysAsMuseScore4() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("dynamics-voices"))
        #expect(try F.velocities(score, track: 0, pitch: 72) == [49, 49, 49, 49, 96, 96, 96, 96, 80, 80, 80, 80])
        #expect(try F.velocities(score, track: 0, pitch: 64) == [33, 33])
        #expect(try F.velocities(score, track: 1) == [49, 49, 49, 49, 49, 49, 49, 49, 112, 112, 112, 112])
    }
}
