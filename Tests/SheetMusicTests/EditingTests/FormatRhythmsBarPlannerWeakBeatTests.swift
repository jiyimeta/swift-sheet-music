@testable import SheetMusicCore
import Testing

/// Syncopations across a weaker beat and dotted rests (folino's owner, 2026-10-30). The cases come from the owner's
/// "また会おう" arrangement, which stays out of the repository; the expected spellings are the owner's rulings, not
/// the Python reference's (which follows MuseScore here).
extension FormatRhythmsBarPlannerTests {
    @Test("a 16th~16th tie across beat 4 stays tied; MuseScore merges it into an 8th")
    func sixteenthTieAcrossBeatFourStays() throws {
        let voice = Self.voice([
            Self.note(1, 2), Self.note(1, 8, pitch: 62), Self.rest(1, 16),
            Self.note(1, 16, pitch: 64, tieForward: true), Self.note(1, 16, pitch: 64, tieBack: true),
            Self.note(1, 8, pitch: 65), Self.note(1, 16, pitch: 67),
        ])
        #expect(Self.respell(voice) == nil)
        let merged = try #require(Self.respell(voice, Self.facts(), .museScore))
        #expect(Self.tokens(merged.slots) == ["C:1/2", "C:1/8", "R:1/16", "C:1/8", "C:1/8", "C:1/16"])
    }

    @Test("a written 16th-grid syncopation across beat 4 splits at the beat; MuseScore keeps it")
    func writtenSixteenthSyncopationSplits() throws {
        let voice = Self.voice([
            Self.note(1, 2), Self.note(1, 8, pitch: 62), Self.rest(1, 16), Self.note(1, 8, pitch: 64),
            Self.note(1, 16, pitch: 65), Self.note(1, 8, pitch: 67),
        ])
        let result = try #require(Self.respell(voice))
        #expect(Self.tokens(result.slots) == ["C:1/2", "C:1/8", "R:1/16", "C:1/16~", "C:1/16", "C:1/16", "C:1/8"])
        #expect(result.slots[3].identity == .keep(voice.elements.eid(at: 3)))
        #expect(Self.respell(voice, Self.facts(), .museScore) == nil)
    }

    @Test("written 2+3+3 and 3+3+2 dotted eighths stay; the same spans tied are not merged into them")
    func dottedEighthGroupingsStay() throws {
        let twoThreeThree = Self.voice([
            Self.note(1, 2), Self.rest(1, 8), Self.note(3, 16, pitch: 62), Self.note(3, 16, pitch: 64),
        ])
        #expect(Self.respell(twoThreeThree) == nil)
        let threeThreeTwo = Self.voice([
            Self.note(3, 16), Self.note(3, 16, pitch: 62), Self.note(1, 8, pitch: 64), Self.note(1, 2, pitch: 65),
        ])
        #expect(Self.respell(threeThreeTwo) == nil)
        let tied = Self.voice([
            Self.note(1, 2), Self.rest(1, 8), Self.note(1, 8, pitch: 62, tieForward: true),
            Self.note(1, 16, pitch: 62, tieBack: true), Self.note(3, 16, pitch: 64),
        ])
        #expect(Self.respell(tied) == nil)
        // MuseScore cuts the written dotted eighth across beat 4.
        let cut = try #require(Self.respell(twoThreeThree, Self.facts(), .museScore))
        #expect(Self.tokens(cut.slots) == ["C:1/2", "R:1/8", "C:1/8~", "C:1/16", "C:3/16"])
    }

    @Test("a quarter~dotted-eighth tie from beat 1 still merges into a double-dotted quarter")
    func doubleDottedQuarterFromTheBeatMerges() throws {
        let voice = Self.voice([
            Self.note(1, 4, tieForward: true), Self.note(3, 16, tieBack: true), Self.note(1, 16, pitch: 62),
            Self.note(1, 2, pitch: 64),
        ])
        let result = try #require(Self.respell(voice))
        #expect(Self.tokens(result.slots) == ["C:7/16", "C:1/16", "C:1/2"])
        let singleDots = RhythmSpellingPolicy(dotLevel: .single, midBarSyncopations: .split)
        #expect(Self.respell(voice, Self.facts(), singleDots) == nil)
    }

    @Test("a dotted rest is written out where the beat is undotted, and kept in compound time")
    func dottedRestsWrittenOut() throws {
        let voice = Self.voice([Self.note(3, 4), Self.rest(3, 16), Self.note(1, 16, pitch: 62)])
        let result = try #require(Self.respell(voice))
        #expect(Self.tokens(result.slots) == ["C:3/4", "R:1/8", "R:1/16", "C:1/16"])
        #expect(Self.respell(voice, Self.facts(), .museScore) == nil)
        let compound = Self.voice([Self.rest(3, 8), Self.note(3, 8)])
        #expect(Self.respell(compound, Self.facts(meter: (6, 8))) == nil)
    }
}
