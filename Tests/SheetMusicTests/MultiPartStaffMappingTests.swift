import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

@Suite struct MultiPartStaffMappingTests {
    private static func loadMixed() throws -> Score {
        let url = try #require(Bundle.module.url(
            forResource: "multiPartMixedStaves",
            withExtension: "mscx"
        ))
        return try MSCXParser.parse(contentsOf: url)
    }

    @Test func partsAndStavesShape() throws {
        let s = try Self.loadMixed()
        #expect(s.parts.count == 4)
        #expect(s.parts[2].staves.count == 2)
        #expect(s.parts[2].staves[0].defaultClefType == "G")
        #expect(s.parts[2].staves[1].defaultClefType == "F")
        #expect(s.allStaves.count == 5)
    }

    @Test func displayOrderMatchesSpec() throws {
        let s = try Self.loadMixed()
        let addrs = s.allStaves.map(\.address)
        #expect(addrs == [
            StaffAddress(partIndex: 0, staffIndexInPart: 0),
            StaffAddress(partIndex: 1, staffIndexInPart: 0),
            StaffAddress(partIndex: 2, staffIndexInPart: 0),
            StaffAddress(partIndex: 2, staffIndexInPart: 1),
            StaffAddress(partIndex: 3, staffIndexInPart: 0),
        ])
    }

    @Test func midi01IdLessFallback() throws {
        let url = try #require(Bundle.module.url(
            forResource: "midi01", withExtension: "mscx"
        ))
        let s = try MSCXParser.parse(contentsOf: url)
        #expect(s.parts.count == 1)
        #expect(s.parts[0].staves.count == 1)
        #expect(s.parts[0].staves[0].measures.isEmpty == false)
    }

    @Test func unclaimedTopLevelStaffThrows() throws {
        // 1 declared Staff in 1 Part, but 2 top-level staves → must throw.
        let measureXml = "<Measure><voice><Rest>" +
            "<durationType>measure</durationType>" +
            "<duration>4/4</duration>" +
            "</Rest></voice></Measure>"
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.60"><Score><Division>480</Division>
        <Part id="1">
          <Staff id="1"><StaffType group="pitched"><name>stdNormal</name></StaffType></Staff>
          <Instrument id="voice"><longName>X</longName></Instrument>
        </Part>
        <Staff id="1">\(measureXml)</Staff>
        <Staff id="9">\(measureXml)</Staff>
        </Score></museScore>
        """
        let data = try #require(xml.data(using: .utf8))
        #expect(throws: SheetMusicError.self) {
            _ = try MSCXParser.parse(data)
        }
    }
}
