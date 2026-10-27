import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicMusicXML
import Testing

/// MuseScore's fixtures for the notation its import adds to what a file spells out (`src/importexport/musicxml/tests/
/// data/`), each judged against the `.mscx` MuseScore 4.7.4 wrote from it (`mscore --musicxml-infer-text-type -o`), as
/// `ScoreSemanticComparison` sees them under the direction fixtures' allowances: written accidentals with their
/// brackets and roles (testAccidentals1-3), an implicit pickup (testImplicitMeasure1), and one- and two-note tremolos
/// with a poet among the creators (testTremolo).
@Suite("MusicXML notation fixtures")
struct MusicXMLNotationFixtureTests {
    private typealias F = DirectionFixtures

    static let fixtures: [String] = [
        "testAccidentals1",
        "testAccidentals2",
        "testAccidentals3",
        "testImplicitMeasure1",
        "testTremolo",
    ]

    @Test("MuseScore's notation fixtures import as MuseScore reads them", arguments: fixtures)
    func matchesMuseScore(_ fixture: String) throws {
        let produced = try MusicXMLParser.parse(MusicXMLFixtureLoader.xml(fixture))
        let reference = try MSCXParser.parse(MusicXMLFixtureLoader.referenceMscx(fixture))
        // MuseScore gives the guitar of testTremolo its template's strings, which MusicXML does not carry.
        ScoreSemanticComparison.assertEquivalent(
            produced: MusicXMLTupletImportTests.withoutStringData(produced),
            reference: MusicXMLTupletImportTests.withoutStringData(reference),
            options: MusicXMLImportTests.directionOptions,
        )
    }

    @Test("every creator is a meta tag named by its type, as MuseScore names it")
    func everyCreatorIsAMetaTag() throws {
        let document = try #require(String(bytes: F.data(parts: [([F.fourQuarters], 1)]), encoding: .utf8))
        let creators = "<identification><creator type=\"poet\">Leon</creator><creator type=\"editor\">Ed</creator>"
            + "<creator>Anon</creator></identification><part-list>"
        let marked = document.replacingOccurrences(of: "<part-list>", with: creators)
        let score = try MusicXMLParser.parse(Data(marked.utf8))
        #expect(score.metaTags["poet"] == "Leon")
        #expect(score.metaTags["editor"] == "Ed")
        // A creator with no type stays the composer, where MuseScore would name a tag with no name.
        #expect(score.metaTags["composer"] == "Anon")
    }
}
