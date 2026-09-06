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

        let encoded = XMLTreeSerializer.serialize(tempo.encode())
        let xml = try #require(String(bytes: encoded, encoding: .utf8))

        #expect(xml.contains("<sym>metNoteQuarterUp</sym>"))
        #expect(xml.contains("<b> = 120</b>"))
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
}
