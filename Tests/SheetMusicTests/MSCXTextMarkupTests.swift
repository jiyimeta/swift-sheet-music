import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

@Suite("MSCX inline text markup")
struct MSCXTextMarkupTests {
    @Test("committed Marker markup round-trips byte-identically")
    func committedMarkerMarkupRoundTrips() throws {
        let source = try MSCXFixtureLoader.mscxData("repeat53")
        let sourceXML = try #require(String(bytes: source, encoding: .utf8))
        let subtree = "<text><sym>segno</sym></text>"
        let encoded = try MSCXEncoder.encode(MSCXParser.parse(source))
        let xml = try #require(String(bytes: encoded, encoding: .utf8))

        #expect(sourceXML.contains(subtree))
        #expect(xml.contains(subtree))
    }

    @Test("stale markup is dropped after text changes")
    func staleMarkupIsDropped() throws {
        let textNode = try XMLTreeParser.parse(
            Data("<text>a<b>B</b>c</text>".utf8),
            preservingMixedContentIn: ["text"],
        )
        let markup = try #require(StaffText.preservedTextMarkup(of: textNode))
        #expect(markup.plainText == "acB")
        var marker = Marker(
            kind: .other,
            text: StaffText.plainText(of: textNode),
            preservedTextMarkup: markup,
        )
        marker.text = "edited"

        let encoded = XMLTreeSerializer.serialize(marker.encode())
        let xml = try #require(String(bytes: encoded, encoding: .utf8))

        #expect(xml.contains("<text>edited</text>"))
        #expect(!xml.contains("<b>"))
    }

    @Test("nested markup keeps character positions through model encoding")
    func nestedMarkupPreservesInterleaving() throws {
        let source = "<text>a<b>B<i>C</i>D</b>e</text>"
        let textNode = try XMLTreeParser.parse(
            Data(source.utf8),
            preservingMixedContentIn: ["text"],
        )
        let markup = try #require(StaffText.preservedTextMarkup(of: textNode))
        let marker = Marker(
            kind: .other,
            text: StaffText.plainText(of: textNode),
            preservedTextMarkup: markup,
        )

        let encoded = XMLTreeSerializer.serialize(marker.encode())
        let xml = try #require(String(bytes: encoded, encoding: .utf8))

        #expect(xml.contains(source))
    }

    @Test("emitPreservedMarkup false emits plain text")
    func preservedMarkupOptionDropsInlineMarkup() throws {
        let textNode = try XMLTreeParser.parse(
            Data("<text><sym>segno</sym></text>".utf8),
            preservingMixedContentIn: ["text"],
        )
        let markup = try #require(StaffText.preservedTextMarkup(of: textNode))
        let marker = Marker(
            kind: .segno,
            text: "segno",
            preservedTextMarkup: markup,
        )
        var options = MSCXEncoderOptions()
        options.emitPreservedMarkup = false

        let encoded = XMLTreeSerializer.serialize(marker.encode(options: options))
        let xml = try #require(String(bytes: encoded, encoding: .utf8))

        #expect(xml.contains("<text>segno</text>"))
        #expect(!xml.contains("<sym>"))
    }

    @Test("Tempo regenerates markup after its model changes")
    func tempoRegeneratesMarkup() throws {
        let source = """
        <Tempo>
          <tempo>6.66667</tempo>
          <followText>1</followText>
          <text><b></b><font face="ScoreText"/><b><font face="FreeSerif"/> = 400</b></text>
        </Tempo>
        """
        let node = try XMLTreeParser.parse(
            Data(source.utf8),
            preservingMixedContentIn: ["text"],
        )
        var tempo = try Tempo.decode(node)
        tempo.beatsPerSecond = 2

        let encoded = XMLTreeSerializer.serialize(tempo.encode(eid: .invalid))
        let xml = try #require(String(bytes: encoded, encoding: .utf8))

        #expect(xml.contains("<sym>metNoteQuarterUp</sym>"))
        #expect(xml.contains("<text><sym>metNoteQuarterUp</sym> = 120</text>"))
        #expect(!xml.contains("<font"))
    }

    @Test("inline markup does not change the score fingerprint")
    func markupDoesNotChangeFingerprint() throws {
        let textNode = try XMLTreeParser.parse(
            Data("<text>R<b></b></text>".utf8),
            preservingMixedContentIn: ["text"],
        )
        let markup = try #require(StaffText.preservedTextMarkup(of: textNode))
        let plain = score(with: Sticking(text: "R"))
        let marked = score(with: Sticking(
            text: "R",
            preservedTextMarkup: markup,
        ))

        #expect(plain.stableFingerprint == marked.stableFingerprint)
    }

    private func score(with sticking: Sticking) -> Score {
        let measure = Measure(voices: [Voice(elements: [.sticking(sticking)])])
        let staff = Staff(measures: [measure])
        let part = Part(
            id: "1",
            instrument: Instrument(id: "voice"),
            staves: [staff],
        )
        return Score(division: 480, parts: [part])
    }

    // MARK: - Source-ordered plain text (import fidelity W1)

    private static func parse(_ xml: String) throws -> XMLTreeNode {
        try XMLTreeParser.parse(Data(xml.utf8), preservingMixedContentIn: ["text"])
    }

    private static func xml(_ node: XMLTreeNode) throws -> String {
        try #require(String(bytes: XMLTreeSerializer.serialize(node), encoding: .utf8))
    }

    @Test("a <br/> is a line break in every carrier that reads <text> (F1.1)")
    func lineBreakInEveryCarrier() throws {
        let text = "<text>poco a poco<br/>cresc.</text>"
        let expected = "poco a poco\ncresc."
        let staff = try Self.parse("<StaffText>\(text)</StaffText>")
        #expect(try StaffText.decode(staff, isSystemText: false).text == expected)
        #expect(Swing.decode(staff, isSystemText: false).text == expected)
        #expect(try RehearsalMark.decode(Self.parse("<RehearsalMark>\(text)</RehearsalMark>")).text == expected)
        let change = try InstrumentChange.decode(Self.parse("<InstrumentChange>\(text)</InstrumentChange>"))
        #expect(change.text == expected)
        #expect(try ExpressionText.decode(Self.parse("<Expression>\(text)</Expression>")).text == expected)
        #expect(try Fingering.decode(Self.parse("<Fingering>\(text)</Fingering>")).text == expected)
        #expect(try Sticking.decode(Self.parse("<Sticking>\(text)</Sticking>")).text == expected)
        #expect(try Capo.decode(Self.parse("<Capo>\(text)</Capo>")).text == expected)
        #expect(try StringTunings.decode(Self.parse("<StringTunings>\(text)</StringTunings>")).text == expected)
        #expect(try FiguredBass.decode(Self.parse("<FiguredBass>\(text)</FiguredBass>")).text == expected)
    }

    @Test("formatting no longer reorders text, and the carrier reads its runs (F1.2)")
    func boldFirstKeepsOrder() throws {
        let staffText = try StaffText.decode(
            Self.parse("<StaffText><text><b>Solo</b> ad lib.</text></StaffText>"), isSystemText: false,
        )
        #expect(staffText.text == "Solo ad lib.")
        #expect(staffText.richText?.lines == [[
            .text("Solo", RichTextFormat(bold: true)), .text(" ad lib.", RichTextFormat(bold: false)),
        ]])
    }

    @Test("a <sym> is a glyph, not text: its name stays out of the plain text (F1.2)")
    func symbolStaysOutOfText() throws {
        let staffText = try StaffText.decode(
            Self.parse("<StaffText><text>senza <sym>keyboardPedalPed</sym></text></StaffText>"), isSystemText: false,
        )
        #expect(staffText.text == "senza ")
        #expect(staffText.richText?.lines.first?.last == .symbol(name: "keyboardPedalPed", RichTextFormat()))
    }

    /// Review Focus 2.
    @Test("an edited carrier is plain text: no runs, and it saves plain")
    func editedCarrierIsPlain() throws {
        var staffText = try StaffText.decode(
            Self.parse("<StaffText><text><b>Solo</b> ad lib.</text></StaffText>"), isSystemText: false,
        )
        staffText.text = "Tutti"
        #expect(staffText.richText == nil)
        let xml = try Self.xml(staffText.encode(eid: .invalid))
        #expect(xml.contains("<text>Tutti</text>"))
        #expect(!xml.contains("<b>"))
    }

    @Test("an unedited formatted carrier writes its markup back byte for byte")
    func unchangedMarkupRoundTrips() throws {
        let source = "<text>poco <i>a</i> poco<br/>cresc.</text>"
        let staffText = try StaffText.decode(Self.parse("<StaffText>\(source)</StaffText>"), isSystemText: false)
        #expect(try Self.xml(staffText.encode(eid: .invalid)).contains(source))
    }

    @Test("markers and jumps keep formatted words; a <sym> marker is empty text with a symbol run (F1.5)")
    func markerAndJumpText() throws {
        let measure = try Measure.decode(Self.parse("""
        <Measure>
          <Marker><text><sym>coda</sym></text><label>codab</label><markerType>codab</markerType></Marker>
          <Jump><text><b>D.S. al Coda</b></text><jumpTo>segno</jumpTo><playUntil>coda</playUntil></Jump>
          <voice></voice>
        </Measure>
        """))
        let marker = try #require(measure.markers.first)
        #expect(marker.text.isEmpty)
        #expect(marker.richText?.lines == [[.symbol(name: "coda", RichTextFormat())]])
        #expect(measure.jumps.first?.text == "D.S. al Coda")
    }

    @Test("a glissando label that is only a <sym> is kept and saved, not read as cleared")
    func symbolGlissandoLabelSurvives() throws {
        let root = try Self.parse("""
        <root><Note><pitch>60</pitch><tpc>14</tpc>
          <Spanner type="Glissando"><Glissando><text><sym>keyboardPedalPed</sym></text></Glissando><next/></Spanner>
        </Note></root>
        """)
        let note = try Note.decode(#require(root.first("Note")))
        let glissando = try #require(note.glissando)
        #expect(glissando.text?.isEmpty == true)
        #expect(glissando.richText?.lines == [[.symbol(name: "keyboardPedalPed", RichTextFormat())]])
        #expect(try Self.xml(glissando.encode()).contains("<text><sym>keyboardPedalPed</sym></text>"))
    }
}
