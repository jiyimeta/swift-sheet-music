import Foundation
@testable import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// `<beginText>` is a `TextLineBase` property in MuseScore — the
/// authored label a line spanner prints at its left end. The decoder
/// dropped it, so a `<Spanner type="TextLine">` had no label to render
/// and layout fell back to printing the element's own type name.
@Suite("Spanner beginText")
struct SpannerBeginTextTests {
    private func spanner(_ xml: String) throws -> Spanner {
        let node = try XMLTreeParser.parse(Data(xml.utf8))
        return try Spanner.decode(node)
    }

    @Test func textLineBeginTextIsDecoded() throws {
        let sp = try spanner("""
        <Spanner type="TextLine"><TextLine>
        <beginText>rit.</beginText></TextLine>
        <next><location><measures>1</measures></location></next></Spanner>
        """)
        #expect(sp.beginText == "rit.")
    }

    @Test func anAbsentBeginTextStaysNil() throws {
        let sp = try spanner("""
        <Spanner type="TextLine"><TextLine/>
        <next><location><measures>1</measures></location></next></Spanner>
        """)
        #expect(sp.beginText == nil)
    }

    @Test func beginTextIsReadFromAnySpannerPayload() throws {
        // MuseScore writes `<beginText>` on any TextLineBase subclass,
        // so the decoder must not special-case `<TextLine>`.
        let sp = try spanner("""
        <Spanner type="PalmMute"><PalmMute>
        <beginText>P.M.</beginText></PalmMute>
        <next><location><measures>1</measures></location></next></Spanner>
        """)
        #expect(sp.beginText == "P.M.")
    }

    @Test func beginTextRoundTripsThroughTheEncoder() throws {
        let original = try spanner("""
        <Spanner type="TextLine"><TextLine>
        <beginText>rit.</beginText></TextLine>
        <next><location><measures>1</measures></location></next></Spanner>
        """)
        let reparsed = try Spanner.decode(original.encode())
        #expect(reparsed.beginText == "rit.")
    }

    @Test func escapedMarkupIsMuseScoreXMLText() throws {
        let sp = try spanner("""
        <Spanner type="TextLine"><TextLine>
        <beginText>&lt;sym&gt;keyboardPedalPed&lt;/sym&gt; &lt;b&gt;rit.&lt;/b&gt;</beginText></TextLine>
        <next><location><measures>1</measures></location></next></Spanner>
        """)
        #expect(sp.beginText == "<sym>keyboardPedalPed</sym> <b>rit.</b>")
        #expect(sp.beginRichText?.plainText == " rit.")
        #expect(sp.beginRichText?.lines.first?.first == .symbol(name: "keyboardPedalPed", RichTextFormat()))
        let encoded = try #require(String(bytes: XMLTreeSerializer.serialize(sp.encode()), encoding: .utf8))
        #expect(encoded.contains(
            "<beginText>&lt;sym&gt;keyboardPedalPed&lt;/sym&gt; &lt;b&gt;rit.&lt;/b&gt;</beginText>",
        ))
    }

    @Test func theDrawnLabelIsThePlainProjection() throws {
        let line = Spanner(kind: .textLine, rawType: "TextLine", nextMeasuresOffset: 1, beginText: "<b>rit.</b> poco")
        let chord = Chord(duration: .whole, notes: ChordNotes([Note(pitch: 72, tpc: 14)]))
        let score = Score(division: 480, parts: [Part(
            id: "P1", instrument: Instrument(id: "voice"),
            staves: [Staff(measures: [
                Measure(voices: [Voice(elements: [.spanner(line), .chord(chord)])]),
                Measure(voices: [Voice(elements: [.chord(chord)])]),
            ])],
        )])
        let anchor = try #require(LayoutEngine.collectSpanners(score: score).first)
        #expect(LayoutEngine.layoutLabel(anchor: anchor) == "rit. poco")
    }
}
