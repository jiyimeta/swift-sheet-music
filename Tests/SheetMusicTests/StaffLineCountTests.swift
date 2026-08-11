import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
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
