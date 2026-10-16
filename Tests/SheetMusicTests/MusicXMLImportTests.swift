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
    /// validates the "permissive drop unterminated ties" behavior (a tie
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

    /// Phase 3 — Fermata support. `case fermata(Fermata)` added to `VoiceElement`; both decoders emit it as a
    /// standalone VoiceElement that precedes the chord/rest it decorates (matching MSCX layout). `testTempoLineFermata`
    /// moved to `phase8Fixtures` (W8): its gradual tempo change is imported now. Every other MuseScore fermata fixture
    /// requires grace notes, so the decoder is also exercised against a hand-rolled XML snippet in
    /// `phase3_fermata_decoderUnit()` below.
    static let phase3Fixtures: [String] = []

    /// MuseScore's own MusicXML Import fixtures that carry directions, each judged against its `_ref.mscx` — what
    /// MuseScore itself made of the file, with text-type inference on (`musicxml_tests.cpp:136`). Admitted one at a
    /// time (spec §11): a name is here only when the comparison is empty, and a fixture parked for an asymmetry that is
    /// not a direction's is listed here with the reason. Filled by Step 3, in candidate order. Parked (reason):
    /// - `testInferredTechnique` // parked — m9 "senza sord": MuseScore 4.7.5 reads Mute, current MuseScore
    ///   (P2 getPlayingTechnique, "senza sord" → Open) reads Open; we follow current MuseScore
    static let phase8Fixtures: [String] = [
        "testTempoLineFermata",
        "testInferredTempoText",
        "testInferredTempoText2",
        "testInferredDynamicsExpression",
        "testWedgeOffset",
        "testPlacementDefaults",
        "testPlacementOffsetDefaults",
        "testFinaleDynamics",
        "testPedalChangesBroken",
        "testSibMetronomeMarks",
        "testTempoTextSpace1",
        "testTempoTextSpace2",
        "testTextOrder",
        "testInferredCrescLines",
        "testInferredCrescLines2",
        "testSibRitLine",
        "testSibOttavas",
        "testInferredDynamicRange",
    ]

    static var directionOptions: ScoreSemanticComparison.Options {
        var options = ScoreSemanticComparison.Options()
        options.stripsStaffText = false
        options.sortsAnnotationRuns = true
        options.ignoresLineGeometry = true
        // The refs are `mscore` 4.7.5 saves, not test-mode ones: what its writer adds whatever the MusicXML said.
        options.ignoreMetaTagKeys = ScoreSemanticComparison.appWrittenMetaTagKeys
        options.ignoresPartTrackName = true
        options.ignoresPedalAutoTextPlace = true
        options.ignoresLineHairpinStyledTexts = true
        options.ignoresDefaultFermataPlacement = true
        options.normalizesTrailingEndMarkers = true
        options.roundsTempoToFilePrecision = true
        options.canonicalizesBracketColumns = true
        return options
    }

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

    @Test("direction fixtures are semantically equal to MuseScore's reading", arguments: phase8Fixtures)
    func phase8_directions_semanticEquivalence(_ fixture: String) throws {
        let produced = try MusicXMLFixtureLoader.score(fixture)
        let reference = try MSCXParser.parse(MusicXMLFixtureLoader.referenceMscx(fixture))
        ScoreSemanticComparison.assertEquivalent(
            produced: produced, reference: reference, options: Self.directionOptions,
        )
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
    @Test func phase4_glissando_enumExists() {
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
        // MuseScore's import gives the subtype's file default (`setSymIdAndTimeStretch`), 2.0 for the plain fermata.
        #expect(fermatas == [Fermata(subtype: "fermataAbove", timeStretch: 2.0)])

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

        // testPartNames and testCodaHBox carry MuseScore's implicit brace at `<level>1</level>`, which the import
        // compacts to column 0 (`canonicalizesBracketColumns`).
        var options = ScoreSemanticComparison.Options()
        options.canonicalizesBracketColumns = true
        ScoreSemanticComparison.assertEquivalent(
            produced: fromXml,
            reference: fromMscx,
            options: options,
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

    /// `<rest measure="yes"/>` must be imported as `.rest(duration: .measure)`,
    /// not as a regular rest with a computed duration.
    @Test func restMeasureAttributeProducesMeasureMarker() throws {
        let xml = Data("""
        <?xml version="1.0"?>
        <score-partwise version="4.0">
          <part-list>
            <score-part id="P1"><part-name>Test</part-name></score-part>
          </part-list>
          <part id="P1">
            <measure number="1">
              <attributes>
                <divisions>4</divisions>
                <time><beats>3</beats><beat-type>4</beat-type></time>
              </attributes>
              <note>
                <rest measure="yes"/>
                <duration>12</duration>
              </note>
            </measure>
          </part>
        </score-partwise>
        """.utf8)
        let score = try MusicXMLParser.parse(xml)
        let measure = score.parts[0].staves[0].measures[0]
        let rest = measure.voices.flatMap(\.elements).compactMap { el -> Chord? in
            if case let .chord(c) = el, c.notes.isEmpty { return c }
            return nil
        }.first
        try #require(rest != nil)
        #expect(rest?.duration == .measure)
    }
}
