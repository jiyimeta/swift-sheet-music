import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

private func parseInstrument(_ inner: String) throws -> Instrument {
    let root = try XMLTreeParser.parse(Data("<Instrument>\(inner)</Instrument>".utf8))
    return try Instrument.decode(root)
}

private func parseStringData(_ inner: String, name: String = "StringData") throws -> StringData {
    let root = try XMLTreeParser.parse(Data("<\(name)>\(inner)</\(name)>".utf8))
    return StringData.decode(root)
}

@Suite("StringData model")
struct StringDataModelTests {
    @Test func defaultsAreEmptyAndInstrumentHasNoTuning() {
        let stringData = StringData()
        #expect(stringData.frets == 0)
        #expect(stringData.strings.isEmpty)
        #expect(stringData.stringCount == 0)
        #expect(Instrument(id: "x").stringData == nil)
    }
}

@Suite("StringData MSCX round trip")
struct StringDataMSCXTests {
    @Test func decodesGuitarStringsInFileOrder() throws {
        let stringData = try parseStringData("""
        <frets>20</frets>
        <string>40</string>
        <string>45</string>
        <string>50</string>
        <string>55</string>
        <string>59</string>
        <string>64</string>
        """)
        #expect(stringData.frets == 20)
        #expect(stringData.strings.map(\.pitch) == [40, 45, 50, 55, 59, 64])
    }

    @Test func decodesStringAttributesAsNonzeroIntegers() throws {
        let stringData = try parseStringData("""
        <frets>24</frets>
        <string open="1">67</string>
        <string useFlat="1">59</string>
        <string>55</string>
        <string open="0">50</string>
        """)
        #expect(stringData.strings.map(\.isOpen) == [true, false, false, false])
        #expect(stringData.strings.map(\.useFlat) == [false, true, false, false])
    }

    /// An unreadable `<string>` keeps its slot at pitch 0 rather than vanishing:
    /// `Note.string` indexes this list, so dropping an entry would renumber every
    /// string after it. MuseScore pushes the entry unconditionally
    /// (`rw/read460/tread.cpp:4203-4208`) with `readInt()`'s 0.
    @Test func malformedCosmeticValuesFallBackWithoutLosingASlot() throws {
        let stringData = try parseStringData("""
        <frets>many</frets>
        <string>40</string>
        <string>high</string>
        <string open="many" useFlat="2">45</string>
        """)
        #expect(stringData.frets == 0)
        #expect(stringData.strings == [
            InstrumentString(pitch: 40),
            InstrumentString(pitch: 0),
            InstrumentString(pitch: 45, useFlat: true),
        ])
        // The slot survives the round trip too, so the indices a later reader
        // sees are the same ones the file described.
        #expect(StringData.decode(stringData.encode()).strings.count == 3)
    }

    @Test func instrumentWithoutStringDataHasNoTuning() throws {
        let instrument = try parseInstrument("<trackName>Piano</trackName>")
        #expect(instrument.stringData == nil)
    }

    @Test func legacyTablatureDecodesLikeStringData() throws {
        let legacy = try parseInstrument("""
        <Tablature>
          <frets>20</frets>
          <string>40</string>
          <string useFlat="1">59</string>
        </Tablature>
        """)
        let current = try parseInstrument("""
        <StringData>
          <frets>20</frets>
          <string>40</string>
          <string useFlat="1">59</string>
        </StringData>
        """)
        let decoded = try #require(legacy.stringData)
        #expect(decoded.frets == 20)
        #expect(decoded.strings == [
            InstrumentString(pitch: 40),
            InstrumentString(pitch: 59, useFlat: true),
        ])
        #expect(legacy.stringData == current.stringData)
    }

    /// MuseScore reads both spellings from one branch and lets each occurrence
    /// overwrite the last (`rw/read460/tread.cpp:1043`), so the later element
    /// wins whichever spelling it uses. Only a hand-edited file can carry both.
    @Test func theLastSpellingWinsWhenBothFormsArePresent() throws {
        let modernLast = try parseInstrument("""
        <Tablature><frets>19</frets><string>40</string></Tablature>
        <StringData><frets>24</frets><string>43</string></StringData>
        """)
        #expect(modernLast.stringData?.frets == 24)
        #expect(modernLast.stringData?.strings.map(\.pitch) == [43])

        let legacyLast = try parseInstrument("""
        <StringData><frets>24</frets><string>43</string></StringData>
        <Tablature><frets>19</frets><string>40</string></Tablature>
        """)
        #expect(legacyLast.stringData?.frets == 19)
        #expect(legacyLast.stringData?.strings.map(\.pitch) == [40])
    }

    @Test func preservesAnUnknownNestedChildAndEncodesIt() throws {
        let stringData = try parseStringData("""
        <frets>20</frets>
        <string>40</string>
        <customTuning mode="historic">kept</customTuning>
        """)
        #expect(stringData.preservedMarkup.map(\.name) == ["customTuning"])

        let encoded = stringData.encode()
        let customTuning = try #require(encoded.first("customTuning"))
        #expect(customTuning.attributes == ["mode": "historic"])
        #expect(customTuning.text == "kept")
    }

    @Test func encoderWritesOnlyTrueAttributesAndUsesCurrentElementName() throws {
        let legacy = try parseStringData("""
        <frets>24</frets>
        <string open="1">67</string>
        <string>43</string>
        <string useFlat="1">59</string>
        """, name: "Tablature")
        let encoded = legacy.encode()
        #expect(encoded.name == "StringData")
        #expect(encoded.children.map(\.name) == ["frets", "string", "string", "string"])
        #expect(encoded.all("string").map(\.attributes) == [
            ["open": "1"],
            [:],
            ["useFlat": "1"],
        ])
    }

    @Test func roundTripsModeledAndPreservedContent() throws {
        let decoded = try parseStringData("""
        <frets>24</frets>
        <string open="1">67</string>
        <string useFlat="1">59</string>
        <customTuning mode="historic">kept</customTuning>
        """)
        #expect(StringData.decode(decoded.encode()) == decoded)
    }

    @Test func typedTuningIsNotAlsoPreservedOnInstrument() throws {
        let current = try parseInstrument("""
        <StringData><frets>20</frets><string>40</string></StringData>
        """)
        let legacy = try parseInstrument("""
        <Tablature><frets>20</frets><string>40</string></Tablature>
        """)
        #expect(!current.preservedMarkup.map(\.name).contains("StringData"))
        #expect(!legacy.preservedMarkup.map(\.name).contains("Tablature"))
    }

    /// The preservation gate `continue`s past a fixture it cannot parse, so
    /// this proves `string-data.mscx` is actually being read.
    ///
    /// The fixture carries MuseScore's own five-string banjo tuning
    /// (`share/instruments/instruments.xml`), which is also what makes `frets`
    /// load-bearing here: `StringData::isFiveStringBanjo()` is true for this
    /// tuning, so MuseScore's reader would overwrite the file's 19 with 24 in
    /// `configBanjo5thString()`. This library keeps what the file said.
    @Test func banjoFixtureDecodesItsTuning() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("string-data"))
        let stringData = try #require(score.parts[0].instrument.stringData)
        #expect(stringData.frets == 19)
        #expect(stringData.strings.map(\.pitch) == [67, 50, 55, 59, 62])
        #expect(stringData.strings.map(\.isOpen) == [true, false, false, false, false])
        #expect(stringData.strings.map(\.useFlat) == [false, false, false, false, true])
    }

    @Test func existingGuitarFixtureNowDecodesTypedTuning() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("guitarbend_simple"))
        let instrument = score.parts[0].instrument
        let stringData = try #require(instrument.stringData)
        #expect(stringData.frets == 20)
        #expect(stringData.strings.map(\.pitch) == [40, 45, 50, 55, 59, 64])
        #expect(!instrument.preservedMarkup.map(\.name).contains("StringData"))
    }

    /// `MSCXEncoder+Instrument.swift` claims this slot in a comment; nothing
    /// pinned it. MuseScore writes `<StringData>` before `<MidiAction>` /
    /// `<Articulation>` / `<Channel>` (`rw/write/twrite.cpp:2025-2036`).
    @Test func instrumentWritesTheTuningBeforeArticulationsAndChannels() throws {
        let instrument = try parseInstrument("""
        <StringData><frets>20</frets><string>40</string></StringData>
        <Articulation><name>staccato</name></Articulation>
        <Channel><program value="25"/></Channel>
        """)
        let names = instrument.encode().children.map(\.name)
        let tuning = try #require(names.firstIndex(of: "StringData"))
        let articulation = try #require(names.firstIndex(of: "Articulation"))
        let channel = try #require(names.firstIndex(of: "Channel"))
        #expect(tuning < articulation)
        #expect(tuning < channel)
    }

    /// The nested bag has to honor the caller's opt-out like every other one.
    @Test func suppressingPreservedMarkupReachesTheNestedBag() throws {
        let stringData = try parseStringData("""
        <frets>20</frets>
        <string>40</string>
        <customTuning>kept</customTuning>
        """)
        var options = MSCXEncoderOptions()
        options.emitPreservedMarkup = false
        let names = stringData.encode(options: options).children.map(\.name)
        #expect(names == ["frets", "string"])
    }

    @Test func strippingPreservedMarkupClearsNestedTuningMarkup() throws {
        var score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("string-data"))
        score.parts[0].instrument.stringData?.preservedMarkup = [
            PreservedXML(name: "customTuning"),
        ]
        let stripped = score.strippingPreservedMarkup()
        #expect(stripped.parts[0].instrument.stringData?.preservedMarkup.isEmpty == true)
    }
}
