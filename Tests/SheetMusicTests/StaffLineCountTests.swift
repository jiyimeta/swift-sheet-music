import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
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
