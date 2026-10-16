import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicMusicXML
import Testing

/// Our own direction fixture (`own/directions-all.musicxml`), judged against what MuseScore itself made of it: the
/// `.mscx` files `mscore` wrote from it with `--musicxml-infer-text-type` (`directions-all-infer`) and without it
/// (`directions-all-plain`, MuseScore's shipped default). Unlike MuseScore's own fixtures, nothing here may be parked:
/// every difference is ours to explain.
@Suite("MusicXML — our own direction fixture")
struct MusicXMLMuseScoreImportTests {
    @Test("our own fixture equals MuseScore's reading of it, with inference on and off", arguments: [true, false])
    func ownFixture(infer: Bool) throws {
        let options = MusicXMLImportOptions(inferTextType: infer)
        let produced = try MusicXMLParser.parse(Self.ownData("directions-all", "musicxml"), options: options)
        let mscx = infer ? "directions-all-infer" : "directions-all-plain"
        let reference = try MSCXParser.parse(MSCXFixtureLoader.mscxData(mscx))
        ScoreSemanticComparison.assertEquivalent(
            produced: produced, reference: reference, options: MusicXMLImportTests.directionOptions,
        )
    }

    private static func ownData(_ name: String, _ ext: String) throws -> Data {
        let url = try #require(TestResources.url(forResource: name, withExtension: ext))
        return try Data(contentsOf: url)
    }
}
