import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
import Testing

/// `<Part><show>0</show>` is MuseScore's "hide this instrument in the main
/// score" flag. It must be honored identically for MuseScore 3 and
/// MuseScore 4 files even though the two versions shape `<Part>` / `<Staff>`
/// differently:
///
///   * MS3: `<Part>` has no id; the per-part `<Staff id="N">` carries the id.
///   * MS4: `<Part id="N">` carries the id; the per-part `<Staff>` is id-less
///     (and gains an `<eid>`).
///
/// In both, `<show>` is a direct child of `<Part>`, so a single read covers
/// both shapes. Absent or `<show>1</show>` means visible.
@Suite("Part <show> visibility")
struct PartShowVisibilityTests {
    private static let measure =
        "<Measure><voice><Rest>" +
        "<durationType>measure</durationType><duration>4/4</duration>" +
        "</Rest></voice></Measure>"

    /// MS3 shape: id-less `<Part>`, `<Staff id="N">`, `<show>0</show>` on the
    /// second part.
    private static func ms3XML() -> Data {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="3.02"><Score><Division>480</Division>
        <Part>
          <Staff id="1"><StaffType group="pitched"><name>stdNormal</name></StaffType></Staff>
          <trackName>Lead</trackName>
          <Instrument id="voice"><longName>Lead</longName></Instrument>
        </Part>
        <Part>
          <Staff id="2"><StaffType group="percussion"><name>perc5Line</name></StaffType>\
        <defaultClef>PERC</defaultClef></Staff>
          <show>0</show>
          <trackName>V.P.</trackName>
          <Instrument id="drumset"><longName>V.P.</longName></Instrument>
        </Part>
        <Staff id="1">\(measure)</Staff>
        <Staff id="2">\(measure)</Staff>
        </Score></museScore>
        """
        return Data(xml.utf8)
    }

    /// MS4 shape: `<Part id="N">`, id-less `<Staff>` with `<eid>`,
    /// `<show>0</show>` on the second part.
    private static func ms4XML() -> Data {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.60"><Score><Division>480</Division>
        <Part id="1">
          <Staff><eid>AAA</eid><StaffType group="pitched"><name>stdNormal</name></StaffType></Staff>
          <trackName>Lead</trackName>
          <Instrument id="voice"><longName>Lead</longName></Instrument>
        </Part>
        <Part id="2">
          <Staff><eid>BBB</eid><StaffType group="percussion"><name>perc5Line</name></StaffType>\
        <defaultClef>PERC</defaultClef></Staff>
          <show>0</show>
          <trackName>V.P.</trackName>
          <Instrument id="drumset"><longName>V.P.</longName></Instrument>
        </Part>
        <Staff id="1">\(measure)</Staff>
        <Staff id="2">\(measure)</Staff>
        </Score></museScore>
        """
        return Data(xml.utf8)
    }

    @Test("MS3: <show>0</show> hides its part, others stay visible")
    func ms3HidesShowZeroPart() throws {
        let score = try MSCXParser.parse(Self.ms3XML())
        #expect(score.parts.count == 2)
        #expect(score.parts[0].isVisibleInScore == true)
        #expect(score.parts[1].isVisibleInScore == false)
    }

    @Test("MS4: <show>0</show> hides its part, others stay visible")
    func ms4HidesShowZeroPart() throws {
        let score = try MSCXParser.parse(Self.ms4XML())
        #expect(score.parts.count == 2)
        #expect(score.parts[0].isVisibleInScore == true)
        #expect(score.parts[1].isVisibleInScore == false)
    }

    @Test("<show>1</show> and absent <show> both mean visible")
    func explicitShowOneAndAbsentAreVisible() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.60"><Score><Division>480</Division>
        <Part id="1">
          <Staff><StaffType group="pitched"><name>stdNormal</name></StaffType></Staff>
          <show>1</show>
          <Instrument id="voice"><longName>A</longName></Instrument>
        </Part>
        <Part id="2">
          <Staff><StaffType group="pitched"><name>stdNormal</name></StaffType></Staff>
          <Instrument id="voice"><longName>B</longName></Instrument>
        </Part>
        <Staff id="1">\(Self.measure)</Staff>
        <Staff id="2">\(Self.measure)</Staff>
        </Score></museScore>
        """
        let score = try MSCXParser.parse(Data(xml.utf8))
        #expect(score.parts[0].isVisibleInScore == true)
        #expect(score.parts[1].isVisibleInScore == true)
    }

    @Test("hidden part survives a decode → encode → decode round-trip")
    func showZeroRoundTrips() throws {
        let original = try MSCXParser.parse(Self.ms3XML())
        let encoded = try MSCXEncoder.encode(original)
        let roundTripped = try MSCXParser.parse(encoded)
        #expect(roundTripped.parts[0].isVisibleInScore == true)
        #expect(roundTripped.parts[1].isVisibleInScore == false)
    }

    @Test("an all-visible score emits no <show> element")
    func visiblePartsEmitNoShow() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.60"><Score><Division>480</Division>
        <Part id="1">
          <Staff><StaffType group="pitched"><name>stdNormal</name></StaffType></Staff>
          <Instrument id="voice"><longName>A</longName></Instrument>
        </Part>
        <Staff id="1">\(Self.measure)</Staff>
        </Score></museScore>
        """
        let original = try MSCXParser.parse(Data(xml.utf8))
        let encoded = try MSCXEncoder.encode(original)
        let text = String(bytes: encoded, encoding: .utf8) ?? ""
        #expect(!text.contains("<show>"))
    }
}
