import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicMusicXML
import Testing

/// MuseScore's fixtures for the notation its import adds to what a file spells out (`src/importexport/musicxml/tests/
/// data/`), each judged against the `.mscx` MuseScore 4.7.4 wrote from it (`mscore --musicxml-infer-text-type -o`), as
/// `ScoreSemanticComparison` sees them under the direction fixtures' allowances: written accidentals with their
/// brackets and roles (testAccidentals1-3) and an implicit pickup (testImplicitMeasure1).
@Suite("MusicXML notation fixtures")
struct MusicXMLNotationFixtureTests {
    static let fixtures: [String] = [
        "testAccidentals1",
        "testAccidentals2",
        "testAccidentals3",
        "testImplicitMeasure1",
    ]

    @Test("MuseScore's notation fixtures import as MuseScore reads them", arguments: fixtures)
    func matchesMuseScore(_ fixture: String) throws {
        let produced = try MusicXMLParser.parse(MusicXMLFixtureLoader.xml(fixture))
        let reference = try MSCXParser.parse(MusicXMLFixtureLoader.referenceMscx(fixture))
        ScoreSemanticComparison.assertEquivalent(
            produced: produced, reference: reference, options: MusicXMLImportTests.directionOptions,
        )
    }
}
