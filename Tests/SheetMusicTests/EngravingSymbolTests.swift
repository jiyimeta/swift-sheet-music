import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// `<Note>` fragments, not whole scores: `Note.decode` is the unit under test,
/// and the fixture-level round trip is the preservation gate's job.
private func parseSymbolNote(_ inner: String) throws -> Note {
    let root = try XMLTreeParser.parse(Data("<Note>\(inner)</Note>".utf8))
    return try Note.decode(root)
}

@Suite("EngravingSymbol model")
struct EngravingSymbolModelTests {
    @Test func noteDefaultsToNoSymbols() {
        #expect(Note(pitch: 60, tpc: 14).symbols.isEmpty)
    }

    @Test func noteStoresSeveralSymbolsInDocumentOrder() {
        let note = Note(pitch: 60, tpc: 14, symbols: [
            EngravingSymbol(name: "metNoteQuarterUp"),
            EngravingSymbol(name: "accidentalSharp"),
        ])
        #expect(note.symbols.map(\.name) == ["metNoteQuarterUp", "accidentalSharp"])
    }

    private func fingerprint(_ symbols: [EngravingSymbol]) -> UInt64 {
        var hasher = FNV1a()
        hasher.combineOccupied(symbols, tag: 46)
        return hasher.value
    }

    @Test func fingerprintSeparatesEveryModeledField() {
        let bare = fingerprint([EngravingSymbol(name: "ornamentTrill")])
        #expect(bare != fingerprint([EngravingSymbol(name: "ornamentTurn")]))
        #expect(bare != fingerprint([
            EngravingSymbol(name: "ornamentTrill", scoreFont: "Bravura"),
        ]))
        #expect(bare != fingerprint([
            EngravingSymbol(name: "ornamentTrill", size: 1.5),
        ]))
        #expect(bare != fingerprint([
            EngravingSymbol(name: "ornamentTrill", angle: -12.25),
        ]))
        #expect(bare != fingerprint([EngravingSymbol(
            name: "ornamentTrill",
            elementProperties: ElementProperties(visible: false),
        )]))
        #expect(bare != fingerprint([EngravingSymbol(
            name: "ornamentTrill",
            elementProperties: ElementProperties(
                color: ScoreColor(red: 10, green: 20, blue: 30, alpha: 40),
            ),
        )]))
    }

    @Test func fingerprintIgnoresPreservedMarkup() {
        let bare = EngravingSymbol(name: "ornamentTrill")
        let withBag = EngravingSymbol(
            name: "ornamentTrill",
            preservedMarkup: [PreservedXML(name: "Image")],
        )
        #expect(fingerprint([bare]) == fingerprint([withBag]))
    }

    @Test func fingerprintOfNoSymbolsFeedsNothing() {
        var hasher = FNV1a()
        let before = hasher.value
        hasher.combineOccupied([] as [EngravingSymbol], tag: 46)
        #expect(hasher.value == before)
    }
}

@Suite("EngravingSymbol decoding")
struct EngravingSymbolDecodeTests {
    @Test func decodesBareAndFutureNamesInDocumentOrder() throws {
        let note = try parseSymbolNote("""
        <Symbol><name>metNoteQuarterUp</name></Symbol>
        <Symbol><name>futureGlyphFromMSC6</name></Symbol>
        <pitch>60</pitch><tpc>14</tpc>
        """)
        #expect(note.symbols.map(\.name) == ["metNoteQuarterUp", "futureGlyphFromMSC6"])
        #expect(note.symbols.allSatisfy { $0.scoreFont == nil })
        #expect(note.symbols.allSatisfy { $0.size == nil })
        #expect(note.symbols.allSatisfy { $0.angle == nil })
        #expect(note.symbols.allSatisfy { $0.elementProperties == .default })
        // Hoisted out of `#expect`: SwiftFormat's `preferKeyPath` rejects the
        // trivial closure, and the `#expect` macro's rethrows analysis rejects
        // the key path inline. Binding first satisfies both.
        let everyBagIsEmpty = note.symbols.allSatisfy(\.preservedMarkup.isEmpty)
        #expect(everyBagIsEmpty)
    }

    @Test func decodesStylesAndPreservesNestedChildrenInOrder() throws {
        let note = try parseSymbolNote("""
        <Symbol>
          <name>ornamentTrill</name>
          <font>Bravura</font>
          <symbolsSize>1.5</symbolsSize>
          <symbolAngle>-12.25</symbolAngle>
          <visible>0</visible>
          <color r="10" g="20" b="30" a="40"/>
          <Symbol><name>ornamentTurn</name></Symbol>
          <Image><path>symbol.svg</path><linkPath>symbol.svg</linkPath></Image>
        </Symbol>
        <pitch>60</pitch><tpc>14</tpc>
        """)
        let symbol = try #require(note.symbols.first)
        #expect(symbol.name == "ornamentTrill")
        #expect(symbol.scoreFont == "Bravura")
        #expect(symbol.size == 1.5)
        #expect(symbol.angle == -12.25)
        #expect(symbol.elementProperties == ElementProperties(
            visible: false,
            color: ScoreColor(red: 10, green: 20, blue: 30, alpha: 40),
        ))
        #expect(symbol.preservedMarkup == [
            PreservedXML(name: "Symbol", children: [
                PreservedXML(name: "name", text: "ornamentTurn"),
            ]),
            PreservedXML(name: "Image", children: [
                PreservedXML(name: "path", text: "symbol.svg"),
                PreservedXML(name: "linkPath", text: "symbol.svg"),
            ]),
        ])
    }

    @Test func missingAndEmptyNamesDegradeToEmptyWithDiagnostics() throws {
        let root = try XMLTreeParser.parse(Data("""
        <Note>
          <Symbol/>
          <Symbol><name></name></Symbol>
          <pitch>60</pitch><tpc>14</tpc>
        </Note>
        """.utf8))
        let collector = MSCXDiagnosticCollector()
        let note = try MSCXParserContext.$collector.withValue(collector) {
            try Note.decode(root)
        }
        #expect(note.symbols.map(\.name) == ["", ""])
        #expect(collector.entries.map(\.code) == [
            "mscx.engravingSymbol.missingName",
            "mscx.engravingSymbol.missingName",
        ])
    }

    @Test func scoreFontAliasStaysPreservedAndKeepsItsSpelling() throws {
        let note = try parseSymbolNote("""
        <Symbol><name>ornamentTrill</name><scoreFont>Leland</scoreFont></Symbol>
        <pitch>60</pitch><tpc>14</tpc>
        """)
        let symbol = try #require(note.symbols.first)
        #expect(symbol.scoreFont == nil)
        #expect(symbol.preservedMarkup == [PreservedXML(name: "scoreFont", text: "Leland")])

        let encoded = try #require(note.encode().first("Symbol"))
        #expect(encoded.children.map(\.name) == ["name", "scoreFont"])
        #expect(encoded.first("scoreFont")?.text == "Leland")
        #expect(!encoded.children.contains { $0.name == "font" })
    }

    @Test func symbolIsNotAlsoPreservedOnTheNote() throws {
        let note = try parseSymbolNote("""
        <Symbol><name>metNoteQuarterUp</name></Symbol>
        <pitch>60</pitch><tpc>14</tpc>
        """)
        #expect(!note.preservedMarkup.map(\.name).contains("Symbol"))
    }

    @Test func parenthesisSymbolRemainsExclusiveToNoteParentheses() throws {
        let note = try parseSymbolNote("""
        <Symbol><name>noteheadParenthesisLeft</name></Symbol>
        <Symbol><name>accidentalSharp</name></Symbol>
        <pitch>60</pitch><tpc>14</tpc>
        """)
        #expect(note.parentheses == .left)
        #expect(note.symbols.map(\.name) == ["accidentalSharp"])

        let encoded = note.encode(options: MSCXEncoderOptions(targetVersion: .v3))
        let names = encoded.all("Symbol").compactMap { $0.first("name")?.text }
        #expect(names.filter { $0 == "noteheadParenthesisLeft" }.count == 1)
        #expect(names.filter { $0 == "accidentalSharp" }.count == 1)
        #expect(names.count == 2)
    }
}

@Suite("EngravingSymbol encoding")
struct EngravingSymbolEncodeTests {
    @Test func alwaysWritesNameAndOnlyPresentOptionalFields() {
        let bare = EngravingSymbol(name: "").encode()
        #expect(bare.children.map(\.name) == ["name"])
        #expect(bare.first("name")?.text.isEmpty == true)

        let styled = EngravingSymbol(
            name: "ornamentTrill",
            scoreFont: "Bravura",
            size: 1.5,
            angle: -12.25,
            elementProperties: ElementProperties(visible: false),
        ).encode()
        #expect(styled.children.map(\.name) == [
            "name", "font", "symbolsSize", "symbolAngle", "visible",
        ])
        #expect(styled.first("font")?.text == "Bravura")
        #expect(styled.first("symbolsSize")?.text == "1.5")
        #expect(styled.first("symbolAngle")?.text == "-12.25")
        #expect(styled.first("visible")?.text == "0")
    }

    @Test func sizeAndAngleWriteWithoutAFont() {
        let node = EngravingSymbol(name: "ornamentTrill", size: 1.25, angle: 30).encode()
        #expect(node.children.map(\.name) == ["name", "symbolsSize", "symbolAngle"])
        #expect(node.first("symbolsSize")?.text == "1.25")
        #expect(node.first("symbolAngle")?.text == "30")
    }

    @Test func preservedMarkupCanBeOmitted() {
        var options = MSCXEncoderOptions()
        options.emitPreservedMarkup = false
        let node = EngravingSymbol(
            name: "ornamentTrill",
            preservedMarkup: [PreservedXML(name: "Image")],
        ).encode(options: options)
        #expect(node.children.map(\.name) == ["name"])
    }

    /// `TWrite::writeProperties(const BSymbol*, …)` (`rw/write/twrite.cpp:1930`)
    /// writes the leaf children *before* the base element properties — the
    /// opposite of `ChordBracket`'s `Arpeggio` base (`twrite.cpp:764`), which
    /// writes item properties first. Getting this backwards produces a file
    /// MuseScore still reads correctly, so only an order assertion catches it.
    @Test func leafChildrenPrecedeTheBaseElementProperties() {
        let node = EngravingSymbol(
            name: "ornamentTrill",
            elementProperties: ElementProperties(visible: false),
            preservedMarkup: [
                PreservedXML(name: "Symbol", children: [
                    PreservedXML(name: "name", text: "ornamentTurn"),
                ]),
                PreservedXML(name: "Image", children: [
                    PreservedXML(name: "path", text: "symbol.svg"),
                ]),
            ],
        ).encode()
        #expect(node.children.map(\.name) == ["name", "Symbol", "Image", "visible"])
    }

    @Test func noteWritesSymbolsInItsElementSlotBeforePitch() throws {
        let note = Note(
            pitch: 60,
            tpc: 14,
            fingerings: [Fingering(text: "1")],
            symbols: [EngravingSymbol(name: "ornamentTrill")],
        )
        let names = note.encode().children.map(\.name)
        let fingering = try #require(names.firstIndex(of: "Fingering"))
        let symbol = try #require(names.firstIndex(of: "Symbol"))
        let pitch = try #require(names.firstIndex(of: "pitch"))
        #expect(fingering < symbol)
        #expect(symbol < pitch)
    }

    @Test func roundTripsEverythingModeledAndPreserved() throws {
        let decoded = try parseSymbolNote("""
        <Symbol>
          <name>ornamentTrill</name>
          <font>Bravura</font>
          <symbolsSize>1.5</symbolsSize>
          <symbolAngle>-12.25</symbolAngle>
          <visible>0</visible>
          <Symbol><name>ornamentTurn</name></Symbol>
          <Image><path>symbol.svg</path></Image>
        </Symbol>
        <pitch>60</pitch><tpc>14</tpc>
        """)
        let reDecoded = try Note.decode(decoded.encode())
        #expect(reDecoded.symbols == decoded.symbols)
    }

    /// The preservation gate skips a fixture it cannot parse
    /// (`guard let score = try? MSCXParser.parse(source) else { continue }`),
    /// so this proves `engraving-symbols.mscx` is actually being read and pins
    /// every note-attached symbol value it carries.
    @Test func fixtureDecodesEveryEngravingSymbolItCarries() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("engraving-symbols"))
        let notes = score.parts[0].staves[0].measures
            .flatMap { $0.voices[0].elements }
            .compactMap { element -> Chord? in
                guard case let .chord(chord) = element else { return nil }
                return chord
            }
            .flatMap { Array($0.notes) }
        #expect(notes.count == 4)
        #expect(notes.flatMap(\.symbols).map(\.name) == [
            "metNoteQuarterUp", "futureGlyphFromMSC6", "ornamentTrill",
            "accidentalSharp",
        ])

        let bare = try #require(notes[0].symbols.first)
        #expect(bare.scoreFont == nil)
        #expect(bare.size == nil)
        #expect(bare.angle == nil)
        #expect(bare.elementProperties == .default)
        #expect(bare.preservedMarkup.isEmpty)

        let future = try #require(notes[1].symbols.first)
        #expect(future.name == "futureGlyphFromMSC6")
        #expect(future.scoreFont == nil)
        #expect(future.size == nil)
        #expect(future.angle == nil)
        #expect(future.elementProperties == .default)
        #expect(future.preservedMarkup.isEmpty)

        let styled = try #require(notes[2].symbols.first)
        #expect(styled.name == "ornamentTrill")
        #expect(styled.scoreFont == "Bravura")
        #expect(styled.size == 1.5)
        #expect(styled.angle == -12.25)
        #expect(styled.elementProperties.visible == false)
        #expect(styled.elementProperties.color == nil)
        #expect(styled.preservedMarkup == [
            PreservedXML(name: "Symbol", children: [
                PreservedXML(name: "name", text: "ornamentTurn"),
            ]),
            PreservedXML(name: "Image", children: [
                PreservedXML(name: "path", text: "symbol.svg"),
            ]),
        ])

        #expect(notes[3].parentheses == .left)
        #expect(notes[3].symbols.map(\.name) == ["accidentalSharp"])
        #expect(notes[3].preservedMarkup.isEmpty)
    }

    @Test func strippingPreservedMarkupClearsMainAndGraceSymbolBags() {
        let marker = PreservedXML(name: "unknown")
        let mainNote = Note(
            pitch: 60,
            tpc: 14,
            symbols: [EngravingSymbol(name: "ornamentTrill", preservedMarkup: [marker])],
        )
        let graceNote = Note(
            pitch: 62,
            tpc: 16,
            symbols: [EngravingSymbol(name: "ornamentTurn", preservedMarkup: [marker])],
        )
        let grace = GraceChord(
            graceType: .acciaccatura,
            duration: .eighth,
            notes: ChordNotes([graceNote]),
        )
        let chord = Chord(
            duration: .quarter,
            notes: ChordNotes([mainNote]),
            graceNotesBefore: [grace],
        )
        let score = Score(
            division: 480,
            parts: [Part(
                id: "1",
                instrument: Instrument(id: "piano"),
                staves: [Staff(measures: [Measure(voices: [Voice(elements: [.chord(chord)])])])],
            )],
        )

        let stripped = score.strippingPreservedMarkup()
        guard case let .chord(strippedChord) = stripped.parts[0].staves[0]
            .measures[0].voices[0].elements[0]
        else {
            Issue.record("expected chord")
            return
        }
        #expect(strippedChord.notes[0].symbols[0].preservedMarkup.isEmpty)
        #expect(strippedChord.graceNotesBefore[0].notes[0]
            .symbols[0].preservedMarkup.isEmpty)
    }

    /// The decoder keeps parenthesis glyphs out of `symbols`, but `symbols` is
    /// a `public var`, so a caller can put one there directly. Emitting it
    /// would make encode → decode non-idempotent: `decodeParentheses` reads the
    /// glyph back as `parentheses`, growing a bracket pair the model never had.
    /// Found by review; the decoder-side test above passes without this guard.
    @Test func encodingSkipsAParenthesisGlyphPlacedInSymbolsDirectly() throws {
        let note = Note(
            pitch: 60,
            tpc: 14,
            symbols: [
                EngravingSymbol(name: "noteheadParenthesisLeft"),
                EngravingSymbol(name: "accidentalSharp"),
            ],
        )
        #expect(note.parentheses == .none)

        let encoded = note.encode(options: MSCXEncoderOptions(targetVersion: .v3))
        let names = encoded.all("Symbol").compactMap { $0.first("name")?.text }
        #expect(names == ["accidentalSharp"])

        let redecoded = try Note.decode(encoded)
        #expect(redecoded.parentheses == .none)
        #expect(redecoded.symbols.map(\.name) == ["accidentalSharp"])
    }
}
