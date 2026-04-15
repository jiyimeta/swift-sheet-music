import Foundation
@testable import SheetMusic
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicMusicXML
@testable import SheetMusicXMLTools
import Testing

@Suite("MusicXML import — Phase 0 basics")
struct MusicXMLImportTests {
    /// Phase 0 fixtures: features already supported by the current Score model
    /// (no Core extensions needed). See
    /// `docs/superpowers/specs/2026-04-15-musicxml-import-design.md`.
    /// Phase 0 ships with the 5 fixtures that don't require MuseScore-specific
    /// semantic quirks outside our decoder scope. Two initially-planned
    /// fixtures were moved to a later PR:
    /// - `testArpOnRest`: MuseScore's importer transfers `<arpeggiate>` from a
    ///   rest to the next voice's chord. That cross-voice rewrite isn't worth
    ///   building for Phase 0.
    /// - `testArpCrossVoice`: merges arpeggios in adjacent voices into one
    ///   arpeggio on a single chord. Same reason.
    static let phase0Fixtures: [String] = [
        "testBarlineLoc",
        "testCopyrightScale",
        "testDurationLargeError",
        "testPartNames",
        "testUnnecessaryBarlines",
    ]

    /// Phase 1 — tie support. `Note.tieForward` / `Note.tieBack` added in
    /// both decoders. This PR ships with `testUnterminatedTies` only: it
    /// validates the "permissive drop unterminated ties" behaviour (a tie
    /// start whose very next same-voice chord isn't the same pitch is
    /// silently dropped, matching MuseScore). The `importTie1`-`4`
    /// fixtures trip orthogonal asymmetries (explicit `<BarLine/>`s at
    /// measure ends that MuseScore's .mscx exporter injects but our
    /// MusicXML decoder doesn't synthesise; trackName divergence where
    /// Sibelius/Audiveris encoders use an `<instrument-name>` different
    /// from `<part-name>`) and are reserved for a follow-up PR.
    static let phase1Fixtures: [String] = [
        "testUnterminatedTies",
    ]

    @Test(arguments: phase0Fixtures)
    func phase0_semanticEquivalence(_ fixture: String) throws {
        try runSemanticEquivalence(fixture: fixture)
    }

    @Test(arguments: phase1Fixtures)
    func phase1_tie_semanticEquivalence(_ fixture: String) throws {
        try runSemanticEquivalence(fixture: fixture)
    }

    private func runSemanticEquivalence(fixture: String) throws {
        let xml = try MusicXMLFixtureLoader.xml(fixture)
        let mscx = try MusicXMLFixtureLoader.referenceMscx(fixture)

        let fromXml = try MusicXMLParser.parse(xml)
        let fromMscx = try MSCXParser.parse(mscx)

        ScoreSemanticComparison.assertEquivalent(
            produced: fromXml,
            reference: fromMscx
        )
    }

    @Test func rejectsTimewiseRoot() throws {
        let timewise = Data(#"<?xml version="1.0"?><score-timewise/>"#.utf8)
        #expect(throws: SheetMusicError.self) {
            _ = try MusicXMLParser.parse(timewise)
        }
    }

    @Test func rejectsUnknownRoot() throws {
        let unknown = Data(#"<?xml version="1.0"?><unknown-root/>"#.utf8)
        #expect(throws: SheetMusicError.self) {
            _ = try MusicXMLParser.parse(unknown)
        }
    }

    @Test func mxlRoundTripMatchesUncompressed() throws {
        let xml = try MusicXMLFixtureLoader.xml("testCopyrightScale")
        let mxl = try MXLTestBuilder.wrap(xml: xml)

        let fromXml = try MusicXMLParser.parse(xml)
        let fromMxl = try MusicXMLParser.parse(mxlData: mxl)

        #expect(fromXml == fromMxl)
    }

    @Test func mxlRejectsMissingContainer() throws {
        let xml = try MusicXMLFixtureLoader.xml("testCopyrightScale")
        let mxl = try MXLTestBuilder.wrapWithoutContainer(xml: xml)
        #expect(throws: SheetMusicError.self) {
            _ = try MusicXMLParser.parse(mxlData: mxl)
        }
    }

    @Test func mxlRejectsDanglingRootfilePath() throws {
        let xml = try MusicXMLFixtureLoader.xml("testCopyrightScale")
        let mxl = try MXLTestBuilder.wrapWithDanglingRootfile(xml: xml)
        #expect(throws: SheetMusicError.self) {
            _ = try MusicXMLParser.parse(mxlData: mxl)
        }
    }
}
