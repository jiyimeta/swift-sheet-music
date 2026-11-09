import Foundation
@testable import SheetMusicBridgeCore
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

/// `<Part><Staff><isStaffVisible>0</isStaffVisible>` is what MuseScore 4 writes when one staff of a part is hidden
/// with the eye beside it in the Instruments panel — the left hand of a piano, say (`TWrite::write(const Staff*)`,
/// `rw/write/twrite.cpp:2795-2797`, only when hidden; read back as `Staff::setVisible(e.readBool())`,
/// `rw/read460/tread.cpp:4078`). It is the per-staff sibling of `<Part><show>0</show>` (`PartShowVisibilityTests`).
@Suite("Staff <isStaffVisible> visibility")
struct StaffVisibilityTests {
    private static let measure =
        "<Measure><voice><Rest>" +
        "<durationType>measure</durationType><duration>4/4</duration>" +
        "</Rest></voice></Measure>"

    /// The shape MuseScore 4.6 saves for a piano whose second staff is hidden: id-less per-part `<Staff>`s with an
    /// `<eid>`, the hide flag after the staff type and before the brace.
    private static func pianoXML(secondStaffFlag: String? = "0", partShow: String? = nil) -> Data {
        let flag = secondStaffFlag.map { "<isStaffVisible>\($0)</isStaffVisible>" } ?? ""
        let show = partShow.map { "<show>\($0)</show>" } ?? ""
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.60"><Score><Division>480</Division>
        <Part id="1">
          <Staff><eid>AAA</eid><StaffType group="pitched"><name>stdNormal</name></StaffType>\
        <bracket type="1" span="2" col="0" visible="1"/></Staff>
          <Staff><eid>BBB</eid><StaffType group="pitched"><name>stdNormal</name></StaffType>\
        <defaultClef>F</defaultClef>\(flag)</Staff>
          \(show)
          <trackName>Piano</trackName>
          <Instrument id="piano"><longName>Piano</longName></Instrument>
        </Part>
        <Staff id="1">\(measure)</Staff>
        <Staff id="2">\(measure)</Staff>
        </Score></museScore>
        """
        return Data(xml.utf8)
    }

    @Test("<isStaffVisible>0</isStaffVisible> hides that staff only, and the part stays visible")
    func zeroHidesOnlyThatStaff() throws {
        let score = try MSCXParser.parse(Self.pianoXML())
        let part = score.parts[0]
        #expect(part.isVisibleInScore)
        #expect(part.staves[0].isVisibleInScore)
        #expect(!part.staves[1].isVisibleInScore)
    }

    @Test("<isStaffVisible>1</isStaffVisible> and an absent flag both mean visible")
    func oneAndAbsentAreVisible() throws {
        for flag in ["1", nil] {
            let score = try MSCXParser.parse(Self.pianoXML(secondStaffFlag: flag))
            #expect(score.parts[0].staves.map(\.isVisibleInScore) == [true, true])
        }
    }

    /// MuseScore reads the flag with `readBool()`, which is `readInt()` (`rw/xmlreader.h:57`): any value that is not a
    /// non-zero integer — `false`, `true`, garbage — reads as 0 and hides the staff. Matched rather than "fixed", so a
    /// file shows here as it shows there.
    @Test("a value that is not a non-zero integer hides the staff, as MuseScore's readInt does")
    func nonIntegerValuesReadAsMuseScoreReadsThem() throws {
        for flag in ["false", "true", " 0 ", ""] {
            let score = try MSCXParser.parse(Self.pianoXML(secondStaffFlag: flag))
            #expect(!score.parts[0].staves[1].isVisibleInScore, "value \(flag)")
        }
        let two = try MSCXParser.parse(Self.pianoXML(secondStaffFlag: "2"))
        #expect(two.parts[0].staves[1].isVisibleInScore)
    }

    @Test("the flag is modeled, not kept as preserved markup")
    func flagIsConsumed() throws {
        let score = try MSCXParser.parse(Self.pianoXML())
        let preservedNames = score.parts[0].staves[1].preservedMarkup.map(\.name)
        #expect(!preservedNames.contains("isStaffVisible"))
    }

    @Test("a hidden staff survives decode → encode → decode, written once and before the staff's brackets")
    func hiddenStaffRoundTrips() throws {
        let original = try MSCXParser.parse(Self.pianoXML())
        let encoded = try MSCXEncoder.encode(original)
        let text = try #require(String(bytes: encoded, encoding: .utf8))
        #expect(text.components(separatedBy: "<isStaffVisible>0</isStaffVisible>").count == 2)

        let roundTripped = try MSCXParser.parse(encoded)
        #expect(roundTripped.parts[0].staves[0].isVisibleInScore)
        #expect(!roundTripped.parts[0].staves[1].isVisibleInScore)
    }

    /// MuseScore writes `<isStaffVisible>` after `<defaultClef>` and before `<bracket>`; written in the same place so a
    /// file saved here diffs against one saved there by content only.
    @Test("the flag is written where MuseScore writes it: after <defaultClef>, before <bracket>")
    func flagSitsBetweenDefaultClefAndBracket() throws {
        var staff = Staff(defaultClefType: "F", brackets: [BracketItem(type: .brace, span: 2, column: 0)])
        staff.isVisibleInScore = false
        let node = staff.encodeDeclaration(eid: .invalid, staffID: "2")
        let names = node.children.map(\.name)
        let flag = try #require(names.firstIndex(of: "isStaffVisible"))
        let clef = try #require(names.firstIndex(of: "defaultClef"))
        let bracket = try #require(names.firstIndex(of: "bracket"))
        #expect(clef < flag)
        #expect(flag < bracket)
        #expect(node.children[flag].text == "0")
    }

    @Test("an all-visible score writes no <isStaffVisible>")
    func visibleStavesWriteNoFlag() throws {
        let original = try MSCXParser.parse(Self.pianoXML(secondStaffFlag: nil))
        let encoded = try MSCXEncoder.encode(original)
        let text = String(bytes: encoded, encoding: .utf8) ?? ""
        #expect(!text.contains("isStaffVisible"))
    }

    // MARK: - Score.authoredHiddenStaffAddresses

    @Test("a hidden staff contributes its own address, and only that one")
    func authoredHiddenFromStaffFlag() throws {
        let score = try MSCXParser.parse(Self.pianoXML())
        #expect(score.authoredHiddenStaffAddresses == [StaffAddress(partIndex: 0, staffIndexInPart: 1)])
    }

    @Test("a hidden part contributes every staff it has")
    func authoredHiddenFromPartShow() throws {
        let score = try MSCXParser.parse(Self.pianoXML(secondStaffFlag: nil, partShow: "0"))
        #expect(score.authoredHiddenStaffAddresses == [
            StaffAddress(partIndex: 0, staffIndexInPart: 0),
            StaffAddress(partIndex: 0, staffIndexInPart: 1),
        ])
    }

    @Test("a hidden part and a hidden staff in it are counted once")
    func authoredHiddenUnion() throws {
        let score = try MSCXParser.parse(Self.pianoXML(secondStaffFlag: "0", partShow: "0"))
        #expect(score.authoredHiddenStaffAddresses.count == 2)
    }

    @Test("a score that hides nothing has no authored-hidden staves")
    func authoredHiddenEmpty() throws {
        let score = try MSCXParser.parse(Self.pianoXML(secondStaffFlag: nil))
        #expect(score.authoredHiddenStaffAddresses.isEmpty)
    }

    // MARK: - PartsStavesWire

    @Test("the parts/staves descriptor marks each staff the file hides, by staff flag or by part")
    func descriptorCarriesAuthoredHidden() throws {
        let staffHidden = try PartsStavesWire(score: MSCXParser.parse(Self.pianoXML()))
        #expect(staffHidden.parts[0].staves.map(\.isAuthoredHidden) == [0, 1])
        #expect(staffHidden.parts[0].isVisibleInScore == 1)

        let partHidden = try PartsStavesWire(score: MSCXParser.parse(
            Self.pianoXML(secondStaffFlag: nil, partShow: "0"),
        ))
        #expect(partHidden.parts[0].staves.map(\.isAuthoredHidden) == [1, 1])
    }
}
