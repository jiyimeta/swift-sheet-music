import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMIDI
import SheetMusicMSCX
import Testing

/// Pins `RepeatUnwinder.reevaluateVoltasAfterJump`
/// (`RepeatUnwind/RepeatUnwinder+Jumps.swift`) — the D.S.-into-a-volta
/// path, where the segno target sits inside a volta of a multi-pass
/// repeat loop — against MuseScore's own ground-truth fixtures, rather
/// than a hand-derived sequence.
///
/// Fixtures: `repeat52.mscx` / `repeat53.mscx`
/// (`Tests/SheetMusicTests/Resources/`, GPL-3.0, see `Resources/LICENSE`).
/// Expected playback order taken verbatim (1-based measure numbers) from
/// MuseScore's own `repeat_tests.cpp`:
///   repeat52: "1;2;3; 1; 4;5; 1;2;3; 1; 4;5; 1; 6; 3; 1; 4;5; 1; 6"
///   repeat53: "1;2;3; 1; 4;5; 1;2;3; 1; 4;5; 1; 6; 5; 1;2;3; 1; 4;5; 1; 6"
///
/// BOTH fixtures diverge from ground truth on the FIRST pass through
/// the score — i.e. before `reevaluateVoltasAfterJump` ever runs.
/// Root-caused to an unrelated, pre-existing off-by-one in
/// `ScoreNavigation.collectVoltas`'s `VoltaSpan.endMeasure` (a single
/// measure with an offset-1 volta whose closing `endRepeat` lives on
/// the FOLLOWING plain measure closes the volta one measure too early,
/// so that following measure's own end-repeat never sees the volta as
/// active). See `.superpowers/sdd/followup-repeat52-report.md` for the
/// full diagnosis and a verified one-line candidate fix.
struct RepeatUnwindFixtureTests {
    private static func planIndices(fixture name: String) throws -> [Int] {
        let url = try #require(TestResources.url(forResource: name, withExtension: "mscx"))
        let score = try MSCXParser.parse(contentsOf: url)
        let navigation = ScoreNavigation(score: score)
        return RepeatUnwinder.plan(navigation: navigation).map(\.measureIndex)
    }

    @Test func repeat52JumpIntoVoltaFinalPlaythrough() throws {
        // MuseScore repeat52 ("Jump into volta \"final\" playthrough"):
        // D.S. (jumpTo: segno, playUntil: end) lands on the segno marker
        // inside a chained ||:x3+x3 loop with two voltas ([1,3] and
        // [2,4]) — the jump lands with an active volta, exercising
        // `reevaluateVoltasAfterJump`. Pinned to MuseScore's own
        // repeat_tests.cpp expected order (0-based).
        let expected = [0, 1, 2, 0, 3, 4, 0, 1, 2, 0, 3, 4, 0, 5, 2, 0, 3, 4, 0, 5]
        #expect(try Self.planIndices(fixture: "repeat52") == expected)
    }

    @Test func repeat53JumpIntoVoltaWithRepeats() throws {
        // MuseScore repeat53 ("Jump into volta with repeats"): same shape
        // as repeat52, but the D.S. resumes on volta2 (endings [2,4]),
        // so the jumped-into passage replays its final repeat. Pinned to
        // MuseScore's repeat_tests.cpp expected order (0-based).
        let expected = [
            0, 1, 2, 0, 3, 4, 0, 1, 2, 0, 3, 4, 0, 5, 4, 0, 1, 2, 0, 3, 4, 0, 5,
        ]
        #expect(try Self.planIndices(fixture: "repeat53") == expected)
    }
}
