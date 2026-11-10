import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import SheetMusicXMLTools
import Testing

/// MuseScore's "hide empty staves" settings in the file. Since 4.60 a part and each of its staves carry an `AutoOnOff`
/// string (`<Part><hideWhenEmpty>`, `<Part><hideStavesWhenIndividuallyEmpty>`, `<Part><Staff><hideWhenEmpty>`, read by
/// `rw/read460/tread.cpp:3611-3614`, `4068-4073`, written by `rw/write/twrite.cpp:2518-2524`, `2780-2788`); before,
/// only a staff carried an integer mode, which MuseScore 4.6 converts on reading (`rw/read400/tread.cpp:3315-3387`).
/// `<showIfSystemEmpty>` and the `<Style>` keys are the same in both.
@Suite("Hide-when-empty codec")
struct HideWhenEmptyCodecTests {
    private static let measure =
        "<Measure><voice><Rest>" +
        "<durationType>measure</durationType><duration>4/4</duration>" +
        "</Rest></voice></Measure>"

    /// A 4.60 part that hides its staves, one by one.
    private static let partHidesIndividually =
        "<hideWhenEmpty>on</hideWhenEmpty>" +
        "<hideStavesWhenIndividuallyEmpty>1</hideStavesWhenIndividuallyEmpty>"

    /// One row of MuseScore 4.6's pre-4.60 conversion: a part's staff modes and the style, and what they become.
    private struct LegacyCase: CustomStringConvertible {
        let modes: [Int]
        let global: Bool
        let part: AutoOnOff
        let individually: Bool
        let staves: [AutoOnOff]

        init(_ modes: [Int], _ global: Bool, _ part: AutoOnOff, _ individually: Bool, _ staves: [AutoOnOff]) {
            self.modes = modes
            self.global = global
            self.part = part
            self.individually = individually
            self.staves = staves
        }

        var description: String {
            "\(modes) global \(global)"
        }
    }

    /// One piano part (two staves) and one flute, in `version`'s shape: 4.60 writes id-less part staves, earlier
    /// files carry `id`s. `firstStaff` / `secondStaff` / `flute` are each staff's extra children, `piano` the
    /// piano part's.
    private static func xml(
        version: String = "4.60", style: String = "",
        firstStaff: String = "", secondStaff: String = "", piano: String = "", flute: String = "",
    ) -> Data {
        let text = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="\(version)"><Score><Division>480</Division>
        <Style>\(style)</Style>
        <Part id="1">
          <Staff id="1"><StaffType group="pitched"><name>stdNormal</name></StaffType>\(firstStaff)\
        <bracket type="1" span="2" col="0" visible="1"/></Staff>
          <Staff id="2"><StaffType group="pitched"><name>stdNormal</name></StaffType>\
        <defaultClef>F</defaultClef>\(secondStaff)</Staff>
          <trackName>Piano</trackName>\(piano)
          <Instrument id="piano"><longName>Piano</longName></Instrument>
        </Part>
        <Part id="2">
          <Staff id="3"><StaffType group="pitched"><name>stdNormal</name></StaffType>\(flute)</Staff>
          <trackName>Flute</trackName>
          <Instrument id="flute"><longName>Flute</longName></Instrument>
        </Part>
        <Staff id="1">\(measure)</Staff>
        <Staff id="2">\(measure)</Staff>
        <Staff id="3">\(measure)</Staff>
        </Score></museScore>
        """
        return Data(text.utf8)
    }

    // MARK: - 4.60 strings

    @Test("a 4.60 staff reads its auto / on / off, and anything else as auto")
    func staffStrings() throws {
        for (raw, expected) in [("on", AutoOnOff.on), ("off", .off), ("auto", .auto), ("1", .auto), ("ON", .auto)] {
            let score = try MSCXParser.parse(Self.xml(flute: "<hideWhenEmpty>\(raw)</hideWhenEmpty>"))
            #expect(score.parts[1].staves[0].hideWhenEmpty == expected, "value \(raw)")
        }
        let absent = try MSCXParser.parse(Self.xml())
        #expect(absent.parts.flatMap { $0.staves.map(\.hideWhenEmpty) } == [.auto, .auto, .auto])
    }

    @Test("a 4.60 part reads its hideWhenEmpty and hideStavesWhenIndividuallyEmpty")
    func partStrings() throws {
        let score = try MSCXParser.parse(Self.xml(piano: Self.partHidesIndividually))
        #expect(score.parts[0].hideWhenEmpty == .on)
        #expect(score.parts[0].hideStavesWhenIndividuallyEmpty)
        #expect(score.parts[1].hideWhenEmpty == .auto)
        #expect(!score.parts[1].hideStavesWhenIndividuallyEmpty)
        // `readBool()` is `readInt()`: only a non-zero integer is true.
        let notAnInteger = try MSCXParser.parse(Self.xml(
            piano: "<hideStavesWhenIndividuallyEmpty>true</hideStavesWhenIndividuallyEmpty>",
        ))
        #expect(!notAnInteger.parts[0].hideStavesWhenIndividuallyEmpty)
    }

    @Test("<showIfSystemEmpty> reads as a non-zero integer, in a 4.60 file and an older one alike")
    func showIfSystemEmpty() throws {
        for version in ["4.60", "3.02"] {
            let score = try MSCXParser.parse(Self.xml(
                version: version, secondStaff: "<showIfSystemEmpty>1</showIfSystemEmpty>",
            ))
            #expect(score.parts[0].staves.map(\.showIfSystemEmpty) == [false, true], "version \(version)")
        }
    }

    @Test("the hide settings are modeled, not kept as preserved markup")
    func tagsAreConsumed() throws {
        let score = try MSCXParser.parse(Self.xml(
            secondStaff: "<hideWhenEmpty>off</hideWhenEmpty><showIfSystemEmpty>1</showIfSystemEmpty>",
            piano: Self.partHidesIndividually,
        ))
        let names = score.parts[0].preservedMarkup.map(\.name) + score.parts[0].staves[1].preservedMarkup.map(\.name)
        for tag in ["hideWhenEmpty", "showIfSystemEmpty", "hideStavesWhenIndividuallyEmpty"] {
            #expect(!names.contains(tag), "tag \(tag)")
        }
    }

    // MARK: - Pre-4.60 integers

    /// `rw/read400/tread.cpp:3315-3387`, one row per case it distinguishes.
    @Test("pre-4.60 staff modes convert as MuseScore 4.6 converts them")
    func legacyConversionTable() {
        let rows: [LegacyCase] = [
            // One staff: ALWAYS and NEVER become the part's; AUTO and INSTRUMENT leave it auto.
            LegacyCase([1], false, .on, false, [.auto]),
            LegacyCase([2], true, .off, false, [.auto]),
            LegacyCase([0], true, .auto, false, [.auto]),
            LegacyCase([3], true, .auto, false, [.auto]),
            // Every staff ALWAYS: the part hides them one by one.
            LegacyCase([1, 1], false, .on, true, [.auto, .auto]),
            // Every staff NEVER: the part never hides.
            LegacyCase([2, 2], true, .off, false, [.auto, .auto]),
            // AUTO staves under the global style hide one by one; without it they stay auto.
            LegacyCase([0, 0], true, .auto, true, [.auto, .auto]),
            LegacyCase([0, 0], false, .auto, false, [.auto, .auto]),
            // An INSTRUMENT staff keeps the part hiding them together.
            LegacyCase([0, 3], true, .auto, false, [.auto, .auto]),
            LegacyCase([3, 3], true, .auto, false, [.auto, .auto]),
            // Mixed: ALWAYS / NEVER move to the staff, and an AUTO one still switches individual hiding on.
            LegacyCase([1, 0], true, .auto, true, [.on, .auto]),
            LegacyCase([2, 0], true, .auto, true, [.off, .auto]),
            LegacyCase([1, 2], true, .auto, false, [.on, .off]),
            // A value outside 0...3 matches none of the cases: neither AUTO nor INSTRUMENT, nothing set.
            LegacyCase([7, 0], true, .auto, true, [.auto, .auto]),
            LegacyCase([7, 7], true, .auto, false, [.auto, .auto]),
        ]
        for row in rows {
            let resolved = HideWhenEmptyDecoding.resolveLegacy(staffModes: row.modes, globalHideEmptyStaves: row.global)
            #expect(resolved.part == row.part, "\(row)")
            #expect(resolved.individually == row.individually, "\(row)")
            #expect(resolved.staves == row.staves, "\(row)")
        }
    }

    @Test("a pre-4.60 staff mode reads as readInt reads it: not an integer, or absent, is AUTO")
    func legacyModeReadsAsInteger() {
        #expect(HideWhenEmptyDecoding.legacyMode("1") == 1)
        #expect(HideWhenEmptyDecoding.legacyMode("on") == 0)
        #expect(HideWhenEmptyDecoding.legacyMode(nil) == 0)
    }

    @Test("a 3.x file's integer modes become the 4.60 part and staff settings")
    func legacyFileDecodes() throws {
        let style = "<hideEmptyStaves>1</hideEmptyStaves>"
        let always = try MSCXParser.parse(Self.xml(
            version: "3.02", style: style,
            firstStaff: "<hideWhenEmpty>1</hideWhenEmpty>", secondStaff: "<hideWhenEmpty>1</hideWhenEmpty>",
            flute: "<hideWhenEmpty>2</hideWhenEmpty>",
        ))
        #expect(always.parts[0].hideWhenEmpty == .on)
        #expect(always.parts[0].hideStavesWhenIndividuallyEmpty)
        #expect(always.parts[1].hideWhenEmpty == .off)

        let auto = try MSCXParser.parse(Self.xml(version: "3.02", style: style))
        #expect(auto.parts[0].hideWhenEmpty == .auto)
        #expect(auto.parts[0].hideStavesWhenIndividuallyEmpty)
        #expect(auto.parts[0].staves.map(\.hideWhenEmpty) == [.auto, .auto])
    }

    /// 4.0–4.5 files still write the integer (`rw/rwregister.cpp:50-53`, read410 delegates to read400's conversion).
    @Test("a 4.20 file is read with the integer form too, and its 4.60-style strings mean AUTO")
    func fourTwentyIsLegacy() throws {
        let score = try MSCXParser.parse(Self.xml(
            version: "4.20", firstStaff: "<hideWhenEmpty>2</hideWhenEmpty>",
            secondStaff: "<hideWhenEmpty>on</hideWhenEmpty>", piano: "<hideWhenEmpty>on</hideWhenEmpty>",
        ))
        // [NEVER, AUTO], the style off: NEVER on the first staff, nothing else — the part-level tag is unknown there.
        #expect(score.parts[0].staves.map(\.hideWhenEmpty) == [.off, .auto])
        #expect(score.parts[0].hideWhenEmpty == .auto)
        #expect(!score.parts[0].hideStavesWhenIndividuallyEmpty)
    }

    @Test("the conversion reads <hideEmptyStaves> from the container's score_style.mss")
    func legacyConversionUsesStyleFile() throws {
        let styleFile = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.20"><Style><hideEmptyStaves>1</hideEmptyStaves></Style></museScore>
        """.utf8)
        let score = try MSCXParser.parse(Self.xml(version: "4.20"), styleFileData: styleFile)
        #expect(score.style.hideEmptyStaves)
        #expect(score.parts[0].hideStavesWhenIndividuallyEmpty)
    }

    // MARK: - Style

    @Test("the four style keys are read off <Style>, and default to MuseScore's values")
    func styleKeys() throws {
        let defaults = try ScoreStyle.decode(style: XMLTreeParser.parse(Data("<Style></Style>".utf8)))
        #expect(!defaults.hideEmptyStaves)
        #expect(defaults.dontHideStavesInFirstSystem)
        #expect(!defaults.alwaysShowBracketsWhenHidingStaves)
        #expect(!defaults.alwaysShowSquareBracketsWhenHidingStaves)

        let xml = """
        <Style><hideEmptyStaves>1</hideEmptyStaves><dontHideStavesInFirstSystem>0</dontHideStavesInFirstSystem>\
        <alwaysShowBracketsWhenEmptyStavesAreHidden>1</alwaysShowBracketsWhenEmptyStavesAreHidden>\
        <alwaysShowSquareBracketsWhenEmptyStavesAreHidden>1</alwaysShowSquareBracketsWhenEmptyStavesAreHidden></Style>
        """
        let style = try ScoreStyle.decode(style: XMLTreeParser.parse(Data(xml.utf8)))
        #expect(style.hideEmptyStaves)
        #expect(!style.dontHideStavesInFirstSystem)
        #expect(style.alwaysShowBracketsWhenHidingStaves)
        #expect(style.alwaysShowSquareBracketsWhenHidingStaves)

        // `bool(e.readInt())`: a present value that is not an integer is false.
        let garbage = try ScoreStyle.decode(style: XMLTreeParser.parse(Data(
            "<Style><dontHideStavesInFirstSystem>yes</dontHideStavesInFirstSystem></Style>".utf8,
        )))
        #expect(!garbage.dontHideStavesInFirstSystem)
    }

    @Test("the style keys are read and still saved as the file had them")
    func styleKeysSurviveASave() throws {
        let score = try MSCXParser.parse(Self.xml(style: "<hideEmptyStaves>1</hideEmptyStaves>"))
        #expect(score.style.hideEmptyStaves)
        let text = try #require(try String(data: MSCXEncoder.encode(score), encoding: .utf8))
        #expect(text.contains("<hideEmptyStaves>1</hideEmptyStaves>"))
    }

    // MARK: - Encoding

    @Test("the 4.60 output writes a staff's settings after <defaultClef>, before <isStaffVisible> and <bracket>")
    func staffWritePosition() throws {
        var staff = Staff(defaultClefType: "F", brackets: [BracketItem(type: .brace, span: 2, column: 0)])
        staff.hideWhenEmpty = .off
        staff.showIfSystemEmpty = true
        staff.isVisibleInScore = false
        let names = staff.encodeDeclaration(eid: .invalid, staffID: "2").children.map(\.name)
        let order = ["defaultClef", "hideWhenEmpty", "showIfSystemEmpty", "isStaffVisible", "bracket"]
        let positions = try order.map { try #require(names.firstIndex(of: $0), "tag \($0)") }
        #expect(positions == positions.sorted())
        let node = staff.encodeDeclaration(eid: .invalid, staffID: "2")
        #expect(node.first("hideWhenEmpty")?.text == "off")
        #expect(node.first("showIfSystemEmpty")?.text == "1")
    }

    @Test("the 4.60 output writes a part's settings after <trackName> and before <Instrument>")
    func partWritePosition() throws {
        var part = Part(id: "1", trackName: "Piano", instrument: Instrument(id: "piano"), staves: [Staff()])
        part.hideWhenEmpty = .on
        part.hideStavesWhenIndividuallyEmpty = true
        let node = part.encodeDeclaration(eid: .invalid, partID: "1", staffIDs: ["1"])
        let names = node.children.map(\.name)
        let order = ["trackName", "hideWhenEmpty", "hideStavesWhenIndividuallyEmpty", "Instrument"]
        let positions = try order.map { try #require(names.firstIndex(of: $0), "tag \($0)") }
        #expect(positions == positions.sorted())
        #expect(node.first("hideWhenEmpty")?.text == "on")
        #expect(node.first("hideStavesWhenIndividuallyEmpty")?.text == "1")
    }

    @Test("defaults write nothing")
    func defaultsWriteNothing() throws {
        let text = try #require(try String(data: MSCXEncoder.encode(MSCXParser.parse(Self.xml())), encoding: .utf8))
        for tag in ["hideWhenEmpty", "showIfSystemEmpty", "hideStavesWhenIndividuallyEmpty"] {
            #expect(!text.contains(tag), "tag \(tag)")
        }
    }

    @Test("4.60 settings survive decode → encode → decode, written in the string form")
    func roundTrip() throws {
        let original = try MSCXParser.parse(Self.xml(
            secondStaff: "<hideWhenEmpty>off</hideWhenEmpty><showIfSystemEmpty>1</showIfSystemEmpty>",
            piano: Self.partHidesIndividually,
            flute: "<hideWhenEmpty>on</hideWhenEmpty>",
        ))
        let encoded = try MSCXEncoder.encode(original)
        let text = try #require(String(bytes: encoded, encoding: .utf8))
        #expect(text.contains("<hideWhenEmpty>on</hideWhenEmpty>"))
        #expect(!text.contains("<hideWhenEmpty>1</hideWhenEmpty>"))
        let back = try MSCXParser.parse(encoded)
        #expect(back.parts[0].hideWhenEmpty == .on)
        #expect(back.parts[0].hideStavesWhenIndividuallyEmpty)
        #expect(back.parts[0].staves.map(\.hideWhenEmpty) == [.auto, .off])
        #expect(back.parts[0].staves.map(\.showIfSystemEmpty) == [false, true])
        #expect(back.parts[1].staves[0].hideWhenEmpty == .on)
    }

    /// A 3.x file read and saved again for MuseScore 4.6: the integers come out as what they converted to.
    @Test("a 3.x file's integers are written back as 4.60 strings")
    func legacyFileSavesAsStrings() throws {
        let original = try MSCXParser.parse(Self.xml(
            version: "3.02", firstStaff: "<hideWhenEmpty>1</hideWhenEmpty>",
            secondStaff: "<hideWhenEmpty>1</hideWhenEmpty>",
        ))
        let text = try #require(try String(data: MSCXEncoder.encode(original), encoding: .utf8))
        #expect(text.contains("<hideWhenEmpty>on</hideWhenEmpty>"))
        #expect(text.contains("<hideStavesWhenIndividuallyEmpty>1</hideStavesWhenIndividuallyEmpty>"))
        #expect(!text.contains("<hideWhenEmpty>1</hideWhenEmpty>"))
    }

    // MARK: - 3.02 output

    @Test("the 3.02 output writes each staff's integer mode and no part-level tags")
    func legacyOutput() throws {
        var score = try MSCXParser.parse(Self.xml())
        score.parts.updateValue(at: 0) { piano in
            piano.hideWhenEmpty = .on
            piano.hideStavesWhenIndividuallyEmpty = true
        }
        score.parts.updateValue(at: 1) { flute in
            flute.staves.updateValue(at: 0) { $0.hideWhenEmpty = .off }
        }
        let encoded = try MSCXEncoder.encode(score, options: MSCXEncoderOptions(targetVersion: .v3))
        let text = try #require(String(bytes: encoded, encoding: .utf8))
        #expect(text.components(separatedBy: "<hideWhenEmpty>1</hideWhenEmpty>").count == 3)
        #expect(text.contains("<hideWhenEmpty>2</hideWhenEmpty>"))
        #expect(!text.contains("hideStavesWhenIndividuallyEmpty"))
        let back = try MSCXParser.parse(encoded)
        #expect(back.parts[0].hideWhenEmpty == .on)
        #expect(back.parts[0].hideStavesWhenIndividuallyEmpty)
        #expect(back.parts[1].hideWhenEmpty == .off)
    }

    /// `legacyModes` inverts `resolveLegacy` wherever an integer combination can say the same thing.
    @Test("the 3.02 modes read back to the settings they were written from")
    func legacyModesRoundTrip() {
        typealias Row = (part: AutoOnOff, individually: Bool, staves: [AutoOnOff], global: Bool)
        let exact: [Row] = [
            (.on, true, [.auto, .auto], false),
            (.off, false, [.auto, .auto], true),
            (.on, false, [.auto], false),
            (.off, false, [.auto], false),
            (.auto, true, [.auto, .auto], true),
            (.auto, false, [.auto, .auto], true),
            (.auto, false, [.auto, .auto], false),
            (.auto, true, [.on, .auto], true),
            (.auto, false, [.on, .off], true),
        ]
        for row in exact {
            let staves = row.staves.map { mode in
                var staff = Staff()
                staff.hideWhenEmpty = mode
                return staff
            }
            var part = Part(id: "1", instrument: Instrument(id: "piano"), staves: IdentifiedArray(staves))
            part.hideWhenEmpty = row.part
            part.hideStavesWhenIndividuallyEmpty = row.individually
            let modes = HideWhenEmptyDecoding.legacyModes(of: part, globalHideEmptyStaves: row.global)
            let back = HideWhenEmptyDecoding.resolveLegacy(
                staffModes: modes.map { $0 ?? 0 }, globalHideEmptyStaves: row.global,
            )
            #expect(back.part == row.part, "\(row)")
            #expect(back.staves == row.staves, "\(row)")
            // A single staff hides alone whichever way the flag reads, so only a multi-staff part's flag must match.
            if row.staves.count > 1 {
                #expect(back.individually == row.individually, "\(row)")
            }
        }
    }
}
