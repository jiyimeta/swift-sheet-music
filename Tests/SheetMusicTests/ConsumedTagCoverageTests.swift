import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// Tags that a decoder's consumed set removed from the preserved-markup bag
/// without any model field behind them.
///
/// **Consuming a tag the model does not store is strictly worse than leaving it
/// alone**: the bag is what would otherwise have carried it, so listing it turns
/// a value that used to survive into one that is silently deleted. The
/// preservation gate cannot warn about it either, because that gate counts
/// `parent/child` pairs found in committed fixtures — a tag no fixture carries
/// contributes no pair, lost or not. `own/consumed-tags.mscx` exists to put
/// these tags in front of the gate.
///
/// `<stretch>` and `<noOffset>` were two such tags and are now unconsumed; the
/// rest of this suite is the regression that keeps them that way.
@Suite("Consumed-tag coverage")
struct ConsumedTagCoverageTests {
    private func fixtureScore() throws -> Score {
        try MSCXParser.parse(MSCXFixtureLoader.mscxData("consumed-tags"))
    }

    /// Proves the fixture parses at all. Without this the gate's green says
    /// nothing: it `continue`s past a fixture it cannot decode.
    @Test func theFixtureDecodes() throws {
        let score = try fixtureScore()
        let measures = score.parts[0].staves[0].measures
        #expect(measures.count == 3)
        #expect(score.parts[0].instrument.transposeChromatic == -2)
    }

    @Test func measureStretchAndNumberOffsetReachTheBag() throws {
        let measures = try fixtureScore().parts[0].staves[0].measures
        let names = measures[1].preservedMarkup.map(\.name)
        #expect(names.contains("stretch"))
        #expect(names.contains("noOffset"))
        #expect(measures[1].preservedMarkup.first { $0.name == "stretch" }?.text == "1.5")
    }

    @Test func measureStretchAndNumberOffsetAreWrittenBack() throws {
        let encoded = try MSCXEncoder.encode(fixtureScore())
        let root = try XMLTreeParser.parse(encoded)
        let measures = try #require(root.first("Score")?.first("Staff")).all("Measure")
        #expect(measures[1].first("stretch")?.text == "1.5")
        #expect(measures[1].first("noOffset")?.text == "2")
    }

    /// `<tpc2>` and `<actualKey>` are consumed with no field behind them too,
    /// but they are not losses: the encoder derives both from the part's
    /// transposition, so they come back with the values they had.
    @Test func transpositionDerivedTagsComeBackWithoutBeingStored() throws {
        let encoded = try MSCXEncoder.encode(fixtureScore())
        let root = try XMLTreeParser.parse(encoded)
        let staff = try #require(root.first("Score")?.first("Staff"))
        let firstMeasure = staff.all("Measure")[0]
        let note = try #require(firstMeasure.first("voice")?.first("Chord")?.first("Note"))
        #expect(note.first("tpc")?.text == "14")
        #expect(note.first("tpc2")?.text == "16")
        #expect(firstMeasure.first("voice")?.first("KeySig")?.first("actualKey")?.text == "2")
    }

    /// The staff's default clef is the opposite case: three spellings collapse
    /// into one modeled value, so the pair cannot come back and is allowlisted
    /// rather than preserved. Pinned here so that a change to the collapse has
    /// to face this expectation as well as the allowlist entry.
    @Test func theDefaultClefPairCollapsesToASingleTag() throws {
        let encoded = try MSCXEncoder.encode(fixtureScore())
        let root = try XMLTreeParser.parse(encoded)
        let declaration = try #require(root.first("Score")?.first("Part")?.first("Staff"))
        #expect(declaration.first("defaultClef")?.text == "G")
        let concert = declaration.all("defaultConcertClef")
        let transposing = declaration.all("defaultTransposingClef")
        #expect(concert.isEmpty)
        #expect(transposing.isEmpty)
    }
}
