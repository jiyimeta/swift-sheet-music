import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicMusicXML
@testable import SheetMusicXMLTools
import Testing

struct StaffLineCountDecodeTests {
    /// Shape copied from `PartShowVisibilityTests.swift:27-46`, which is
    /// a known-good minimal document. `<Division>` is REQUIRED —
    /// `MSCXDecoder+Score.swift:26-30` throws `malformedScore` without
    /// it — and `parse` takes its argument unlabeled
    /// (`MSCXParser.swift:13`).
    private func staff(linesXML: String) throws -> Staff {
        let mscx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.60"><Score><Division>480</Division>
        <Part id="1">
          <Staff id="1"><StaffType group="percussion"><name>perc3Line</name>\
        \(linesXML)</StaffType><defaultClef>PERC</defaultClef></Staff>
          <trackName>Drumset</trackName>
          <Instrument id="drumset"><longName>Drumset</longName></Instrument>
        </Part>
        <Staff id="1"><Measure><voice/></Measure></Staff>
        </Score></museScore>
        """
        let score = try MSCXParser.parse(Data(mscx.utf8))
        return score.parts[0].staves[0]
    }

    @Test func readsAThreeLineStaff() throws {
        #expect(try staff(linesXML: "<lines>3</lines>").lineCount == 3)
    }

    @Test func defaultsToFiveWhenAbsent() throws {
        #expect(try staff(linesXML: "").lineCount == 5)
    }

    @Test func defaultsToFiveWhenNonNumeric() throws {
        #expect(try staff(linesXML: "<lines>abc</lines>").lineCount == 5)
    }

    @Test func clampsZeroUpToOne() throws {
        #expect(try staff(linesXML: "<lines>0</lines>").lineCount == 1)
    }

    @Test func clampsAbsurdValuesDown() throws {
        #expect(try staff(linesXML: "<lines>99</lines>").lineCount == 16)
    }

    @Test func defaultInitializerIsFiveLine() {
        #expect(Staff().lineCount == 5)
    }
}

struct StaffLineCountEncodeTests {
    @Test func threeLineStaffSurvivesRoundTrip() throws {
        let staff = Staff(
            staffType: "perc3Line", group: "percussion", lineCount: 3,
            measures: [Measure(voices: [Voice(elements: [])])],
        )
        let node = staff.encodeDeclaration(staffID: "1")
        let staffType = try #require(node.first("StaffType"))
        #expect(staffType.first("lines")?.text == "3")
    }

    @Test func fiveLineStaffOmitsTheElement() {
        let node = Staff().encodeDeclaration(staffID: "1")
        // XMLTreeNode.first(_:) is a custom child lookup, not
        // Sequence.first(where:), so SwiftLint's
        // contains_over_first_not_nil rule fires as a false positive
        // (see InstrumentChangeMSCXTests.swift for the same pattern).
        // swiftlint:disable:next contains_over_first_not_nil
        #expect(node.first("StaffType")?.first("lines") == nil)
    }

    /// The actual user-visible promise: not just that the encoder emits
    /// the right XML shape, but that a parsed 3-line staff still reads
    /// back as 3-line after a full encode → re-parse round trip.
    @Test func threeLineStaffSurvivesFullDocumentRoundTrip() throws {
        let mscx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.60"><Score><Division>480</Division>
        <Part id="1">
          <Staff id="1"><StaffType group="percussion"><name>perc3Line</name>\
        <lines>3</lines></StaffType><defaultClef>PERC</defaultClef></Staff>
          <trackName>Drumset</trackName>
          <Instrument id="drumset"><longName>Drumset</longName></Instrument>
        </Part>
        <Staff id="1"><Measure><voice/></Measure></Staff>
        </Score></museScore>
        """
        let parsed = try MSCXParser.parse(Data(mscx.utf8))
        #expect(parsed.parts[0].staves[0].lineCount == 3)

        let reencoded = try MSCXEncoder.encode(parsed)
        let reparsed = try MSCXParser.parse(reencoded)

        #expect(reparsed.parts[0].staves[0].lineCount == 3)
    }
}

/// Import-only: MusicXML carries the line count at
/// `<attributes><staff-details><staff-lines>N`. There is no MusicXML
/// encoder in this package, so there is nothing to round-trip.
@Suite("MusicXML staff-lines import")
struct MusicXMLStaffLinesTests {
    /// Document shape copied from
    /// `MusicXMLImportTests.swift:101-127` (`phase3_fermata_decoderUnit`),
    /// trimmed to the one measure the line count is declared in.
    private func score(attributes: String, notes: String = """
    <note><rest measure="yes"/><duration>4</duration></note>
    """) throws -> Score {
        let xml = Data("""
        <?xml version="1.0"?>
        <score-partwise version="4.0">
          <part-list>
            <score-part id="P1"><part-name>Test</part-name></score-part>
          </part-list>
          <part id="P1">
            <measure number="1">
              <attributes>
                <divisions>1</divisions>
                <time><beats>4</beats><beat-type>4</beat-type></time>
        \(attributes)
              </attributes>
        \(notes)
            </measure>
          </part>
        </score-partwise>
        """.utf8)
        return try MusicXMLParser.parse(xml)
    }

    private func lineCounts(attributes: String, notes: String? = nil) throws -> [Int] {
        let parsed = try notes.map { try score(attributes: attributes, notes: $0) }
            ?? score(attributes: attributes)
        return parsed.parts[0].staves.map(\.lineCount)
    }

    /// One measure rest on each staff of a two-staff part — enough for
    /// the walker to build both staves.
    private static let twoStaffRests = """
    <note><rest measure="yes"/><duration>4</duration><staff>1</staff></note>
    <note><rest measure="yes"/><duration>4</duration><staff>2</staff></note>
    """

    /// Full-document escape hatch for the lifetime cases the
    /// single-measure / single-part `score(attributes:notes:)` helper
    /// cannot express.
    private func parse(partList: String, parts: String) throws -> Score {
        let xml = Data("""
        <?xml version="1.0"?>
        <score-partwise version="4.0">
          <part-list>\(partList)</part-list>
        \(parts)
        </score-partwise>
        """.utf8)
        return try MusicXMLParser.parse(xml)
    }

    @Test func readsAOneLineStaff() throws {
        #expect(try lineCounts(
            attributes: "<staff-details><staff-lines>1</staff-lines></staff-details>",
        ) == [1])
    }

    @Test func readsAThreeLineStaff() throws {
        #expect(try lineCounts(
            attributes: "<staff-details><staff-lines>3</staff-lines></staff-details>",
        ) == [3])
    }

    @Test func defaultsToFiveWhenAbsent() throws {
        #expect(try lineCounts(attributes: "") == [5])
    }

    @Test func defaultsToFiveWhenStaffDetailsCarriesNoStaffLines() throws {
        #expect(try lineCounts(
            attributes: #"<staff-details print-object="no"/>"#,
        ) == [5])
    }

    @Test func defaultsToFiveWhenNonNumeric() throws {
        #expect(try lineCounts(
            attributes: "<staff-details><staff-lines>abc</staff-lines></staff-details>",
        ) == [5])
    }

    @Test func clampsZeroUpToOne() throws {
        #expect(try lineCounts(
            attributes: "<staff-details><staff-lines>0</staff-lines></staff-details>",
        ) == [1])
    }

    @Test func clampsAbsurdValuesDown() throws {
        #expect(try lineCounts(
            attributes: "<staff-details><staff-lines>99</staff-lines></staff-details>",
        ) == [16])
    }

    /// The `number` attribute is a 1-based staff selector. `number="2"`
    /// must leave staff 1 at the default — a broadcast (or an
    /// `Array(repeating:)` build) would wrongly give both staves 3.
    @Test func numberSelectsASingleStaffOfAMultiStaffPart() throws {
        #expect(try lineCounts(
            attributes: """
                    <staves>2</staves>
                    <staff-details number="2"><staff-lines>3</staff-lines></staff-details>
            """,
            notes: Self.twoStaffRests,
        ) == [5, 3])
    }

    /// An omitted `number` means staff 1, so the second staff of a
    /// two-staff part keeps the default.
    @Test func omittedNumberTargetsTheFirstStaff() throws {
        #expect(try lineCounts(
            attributes: """
                    <staves>2</staves>
                    <staff-details><staff-lines>1</staff-lines></staff-details>
            """,
            notes: Self.twoStaffRests,
        ) == [1, 5])
    }

    /// Both staves of a grand staff can declare their own count.
    @Test func eachStaffCanDeclareItsOwnCount() throws {
        #expect(try lineCounts(
            attributes: """
                    <staves>2</staves>
                    <staff-details number="1"><staff-lines>1</staff-lines></staff-details>
                    <staff-details number="2"><staff-lines>3</staff-lines></staff-details>
            """,
            notes: Self.twoStaffRests,
        ) == [1, 3])
    }

    /// MuseScore's `MusicXmlParserPass2::staffDetails` resets an
    /// out-of-range `number` to index 0 rather than clamping it to the
    /// last staff (`importmusicxmlpass2.cpp:3141-3149` — it logs
    /// "invalid staff-details number" and sets `n = 0`). So `number="3"`
    /// on a two-staff part converts the TOP staff, not the bottom one.
    @Test func outOfRangeNumberFallsBackToTheFirstStaff() throws {
        #expect(try lineCounts(
            attributes: """
                    <staves>2</staves>
                    <staff-details number="3"><staff-lines>1</staff-lines></staff-details>
            """,
            notes: Self.twoStaffRests,
        ) == [1, 5])
    }

    /// Lifetime property 1a: the value must SURVIVE the measures after
    /// the one that declared it. Declared in measure 1 of a two-measure
    /// part, so a refactor that rebuilt `MusicXMLAttributesSnapshot`
    /// per measure would let measure 2 wipe it.
    ///
    /// This is the direction that pins stickiness. The measure-2 case
    /// below does NOT: the walker reads the snapshot after the loop, so
    /// a value written by the LAST measure survives a per-measure reset
    /// and that test would stay green under the bug.
    @Test func staffDetailsSurvivesSubsequentMeasures() throws {
        let score = try parse(
            partList: #"<score-part id="P1"><part-name>T</part-name></score-part>"#,
            parts: """
            <part id="P1">
              <measure number="1">
                <attributes><divisions>1</divisions>
                  <staff-details><staff-lines>3</staff-lines></staff-details>
                </attributes>
                <note><rest measure="yes"/><duration>4</duration></note>
              </measure>
              <measure number="2">
                <attributes><divisions>1</divisions></attributes>
                <note><rest measure="yes"/><duration>4</duration></note>
              </measure>
            </part>
            """,
        )
        #expect(score.parts[0].staves.map(\.lineCount) == [3])
    }

    /// Lifetime property 1b: the line count is staff-level, not
    /// measure-level, so a `<staff-details>` first seen in measure 2
    /// still reaches the `Staff` build rather than being ignored because
    /// it missed the opening attributes.
    @Test func staffDetailsInALaterMeasureStillApplies() throws {
        let score = try parse(
            partList: #"<score-part id="P1"><part-name>T</part-name></score-part>"#,
            parts: """
            <part id="P1">
              <measure number="1">
                <attributes><divisions>1</divisions></attributes>
                <note><rest measure="yes"/><duration>4</duration></note>
              </measure>
              <measure number="2">
                <attributes>
                  <staff-details><staff-lines>3</staff-lines></staff-details>
                </attributes>
                <note><rest measure="yes"/><duration>4</duration></note>
              </measure>
            </part>
            """,
        )
        #expect(score.parts[0].staves.map(\.lineCount) == [3])
    }

    /// Lifetime property 2: the snapshot is constructed fresh inside
    /// `MusicXMLMeasureWalker.decode`, which runs once per `<part>`, so
    /// one part's line count must not bleed into the next. A refactor
    /// that hoisted the snapshot to score scope would break this.
    @Test func lineCountsDoNotLeakBetweenParts() throws {
        let score = try parse(
            partList: """
            <score-part id="P1"><part-name>A</part-name></score-part>
            <score-part id="P2"><part-name>B</part-name></score-part>
            """,
            parts: """
            <part id="P1">
              <measure number="1">
                <attributes><divisions>1</divisions>
                  <staff-details><staff-lines>3</staff-lines></staff-details>
                </attributes>
                <note><rest measure="yes"/><duration>4</duration></note>
              </measure>
            </part>
            <part id="P2">
              <measure number="1">
                <attributes><divisions>1</divisions></attributes>
                <note><rest measure="yes"/><duration>4</duration></note>
              </measure>
            </part>
            """,
        )
        #expect(score.parts.map { $0.staves.map(\.lineCount) } == [[3], [5]])
    }
}
