import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

@Suite struct FermataModelTests {
    @Test func subtypeDefaultsMatchMuseScore() {
        let cases: [(String, Double)] = [
            ("fermataAbove", 1.5),
            ("fermataBelow", 1.5),
            ("fermataShortAbove", 1.5),
            ("fermataShortBelow", 1.5),
            ("fermataLongAbove", 2.0),
            ("fermataLongBelow", 2.0),
            ("fermataLongHenzeAbove", 2.0),
            ("fermataLongHenzeBelow", 2.0),
            ("fermataVeryLongAbove", 3.0),
            ("fermataVeryLongBelow", 3.0),
            ("fermataVeryShortAbove", 1.25),
            ("fermataVeryShortBelow", 1.25),
            ("fermataShortHenzeAbove", 1.25),
            ("fermataShortHenzeBelow", 1.25),
            ("unknownGlyphName", 1.5),
        ]
        for (subtype, expected) in cases {
            let fermata = Fermata(subtype: subtype)
            #expect(fermata.timeStretch == expected, "subtype=\(subtype)")
        }
    }

    @Test func explicitTimeStretchOverridesDefault() {
        let fermata = Fermata(subtype: "fermataAbove", timeStretch: 2.5)
        #expect(fermata.timeStretch == 2.5)
    }

    @Test func mscxDecodesExplicitTimeStretch() throws {
        let xml = """
        <voice>
          <Fermata>
            <subtype>fermataAbove</subtype>
            <timeStretch>2.5</timeStretch>
          </Fermata>
        </voice>
        """
        let voice = try Voice.decode(
            XMLTreeParser.parse(Data(xml.utf8)))
        guard case let .fermata(f) = voice.elements[0] else {
            Issue.record("element 0 is not a fermata"); return
        }
        #expect(f.subtype == "fermataAbove")
        #expect(f.timeStretch == 2.5)
    }

    @Test func mscxDecodeFallsBackToSubtypeDefault() throws {
        let xml = """
        <voice>
          <Fermata><subtype>fermataLongAbove</subtype></Fermata>
        </voice>
        """
        let voice = try Voice.decode(
            XMLTreeParser.parse(Data(xml.utf8)))
        guard case let .fermata(f) = voice.elements[0] else {
            Issue.record("element 0 is not a fermata"); return
        }
        #expect(f.timeStretch == 2.0)
    }
}
