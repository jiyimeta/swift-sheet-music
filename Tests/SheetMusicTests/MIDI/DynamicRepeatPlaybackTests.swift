@testable import SheetMusicCore
@testable import SheetMusicMIDI
import Testing

/// MuseScore 4 reads a note's level from a dynamics map built in playback order (`PlaybackContext::update`,
/// `engraving/playback/playbackcontext.cpp:309-347`; `appliableDynamicLevel`, `:144-158`): a repeat starts with the
/// level in force where the music left — a hairpin's held level too, an accent's never — and lays out again only the
/// hairpins that reach into it (`handleSpanners`, `:540-567`) (owner decision c).
@Suite("Dynamics across repeats")
struct DynamicRepeatPlaybackTests {
    private typealias F = DynamicPlaybackFixtures

    @Test("a return to bar 1 carries the level in force, not mf")
    func levelCarriesIntoTheRepeat() throws {
        let score = F.repeating(F.score([
            [F.quarter, F.quarter, F.quarter, F.quarter],
            [F.dynamic("p"), F.quarter, F.quarter, F.quarter, F.quarter],
        ]), from: 0, through: 1)
        #expect(try F.velocities(score) == [80, 80, 80, 80, 49, 49, 49, 49, 49, 49, 49, 49, 49, 49, 49, 49])
    }

    @Test("a hairpin's held level carries into the repeat")
    func heldLevelCarries() throws {
        let score = F.repeating(F.score([
            [F.quarter, F.quarter, F.quarter, F.quarter],
            [F.dynamic("p"), F.crescendo(), F.quarter, F.quarter, F.quarter, F.quarter],
            [F.quarter, F.quarter, F.quarter, F.quarter],
        ]), from: 0, through: 2)
        #expect(try F.velocities(score) == [
            80, 80, 80, 80, 49, 53, 57, 60, 64, 64, 64, 64,
            64, 64, 64, 64, 49, 53, 57, 60, 64, 64, 64, 64,
        ])
    }

    @Test("a hairpin's hold from before the repeat does not reach into it")
    func aHoldBeforeTheRepeatStaysOutOfIt() throws {
        let score = F.repeating(F.score([
            [F.dynamic("p"), F.crescendo(), F.quarter, F.quarter, F.quarter, F.quarter],
            [F.quarter, F.quarter, F.quarter, F.quarter],
            [F.dynamic("mf"), F.quarter, F.quarter, F.quarter, F.quarter],
        ]), from: 1, through: 2)
        #expect(try F.velocities(score) == [
            49, 53, 57, 60, 64, 64, 64, 64, 80, 80, 80, 80, 80, 80, 80, 80, 80, 80, 80, 80,
        ])
    }

    @Test("an accent on the last chord does not carry")
    func anAccentDoesNotCarry() throws {
        let score = F.repeating(F.score([
            [F.quarter, F.quarter, F.quarter, F.quarter],
            [F.dynamic("p"), F.quarter, F.quarter, F.quarter, F.dynamic("sf"), F.quarter],
        ]), from: 0, through: 1)
        #expect(try F.velocities(score) == [80, 80, 80, 80, 49, 49, 49, 96, 49, 49, 49, 49, 49, 49, 49, 96])
    }
}
