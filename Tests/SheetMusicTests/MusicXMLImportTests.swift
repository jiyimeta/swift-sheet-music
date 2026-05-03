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

    /// Phase 2 — Jump / Marker support. `Measure.jumps` / `Measure.markers`
    /// added in both decoders; maps `<sound dalsegno|dacapo|tocoda|fine|…>`
    /// and `<direction-type><segno|coda>` to MuseScore's navigation model.
    /// `testDSalCoda` was deferred: when a score has both a "To Coda"
    /// jump target and a separate reachable coda after D.S., MuseScore
    /// renames one of the two markers (`coda` → `codab`) to disambiguate.
    /// That rewrite is orthogonal to the decoder and lives in a later PR.
    static let phase2Fixtures: [String] = [
        "testCodaHBox",
    ]

    /// Phase 3 — Fermata support. `case fermata(Fermata)` added to
    /// `VoiceElement`; both decoders emit it as a standalone VoiceElement
    /// that precedes the chord/rest it decorates (matching MSCX layout).
    /// No end-to-end fixture passes yet: `testTempoLineFermata` requires
    /// MuseScore's `GradualTempoChange` spanner support (orthogonal to
    /// fermata), and every other MuseScore fermata fixture requires grace
    /// notes. Instead the decoder is exercised against a hand-rolled XML
    /// snippet in `phase3_fermata_decoderUnit()` below.
    static let phase3Fixtures: [String] = []

    @Test(arguments: phase0Fixtures)
    func phase0_semanticEquivalence(_ fixture: String) throws {
        try runSemanticEquivalence(fixture: fixture)
    }

    @Test(arguments: phase1Fixtures)
    func phase1_tie_semanticEquivalence(_ fixture: String) throws {
        try runSemanticEquivalence(fixture: fixture)
    }

    @Test(arguments: phase2Fixtures)
    func phase2_jumpMarker_semanticEquivalence(_ fixture: String) throws {
        try runSemanticEquivalence(fixture: fixture)
    }

    /// Phase 4 — Glissando.
    ///
    /// `Spanner.Kind.glissando` is added to `SheetMusicCore` so downstream
    /// decoders/renderers can model classic two-note glissandos (the `<Spanner
    /// type="Glissando">` form MuseScore uses for gradual pitch transitions).
    ///
    /// `testGlissFall` is **not** used as a Phase 4 fixture: it exercises
    /// one-sided "falls" that MuseScore stores as `<ChordLine>`, a distinct
    /// Core type that isn't in scope for this PR. A minimal unit test below
    /// confirms the enum case is wired up and round-trips via `Spanner`'s
    /// Equatable.
    @Test func phase4_glissando_enumExists() throws {
        let spanner = Spanner(kind: .glissando, rawType: "Glissando")
        #expect(spanner.kind == .glissando)
        #expect(spanner.kind.rawValue == "Glissando")
    }

    /// Minimal hand-rolled score that just exercises the fermata path.
    /// `<note><notations><fermata/></notations></note>` should emit a
    /// `.fermata` VoiceElement immediately before the chord/rest.
    @Test func phase3_fermata_decoderUnit() throws {
        let xml = Data("""
        <?xml version="1.0"?>
        <score-partwise version="4.0">
          <part-list>
            <score-part id="P1">
              <part-name>X</part-name>
            </score-part>
          </part-list>
          <part id="P1">
            <measure number="1">
              <attributes>
                <divisions>1</divisions>
                <key><fifths>0</fifths></key>
                <time><beats>4</beats><beat-type>4</beat-type></time>
                <clef><sign>G</sign><line>2</line></clef>
              </attributes>
              <note>
                <pitch><step>C</step><octave>5</octave></pitch>
                <duration>4</duration>
                <voice>1</voice>
                <type>whole</type>
                <notations><fermata/></notations>
              </note>
            </measure>
          </part>
        </score-partwise>
        """.utf8)
        let score = try MusicXMLParser.parse(xml)
        let elements = score.parts[0].staves[0].measures[0].voices[0].elements
        let fermatas = elements.compactMap { element -> Fermata? in
            if case let .fermata(f) = element { return f }
            return nil
        }
        #expect(fermatas == [Fermata(subtype: "fermataAbove")])

        // Fermata comes before the chord in voice order.
        let fermataIndex = elements.firstIndex {
            if case .fermata = $0 { true } else { false }
        }
        let chordIndex = elements.firstIndex {
            if case .chord = $0 { true } else { false }
        }
        try #require(fermataIndex != nil)
        try #require(chordIndex != nil)
        #expect(fermataIndex.flatMap { f in chordIndex.map { f < $0 } } == true)
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
