@testable import SheetMusicCore
import Testing

/// Preserved markup read from and written as MuseScore xml text — the string a copied dynamic's own text travels as
/// (`Dynamic.customXMLText`) and `SetDynamic` writes back: what one writes the other reads to the same markup, and the
/// runs it reads are the runs `RichText(xmlText:)` reads from the same string.
@Suite("Preserved markup as xml text")
struct PreservedTextMarkupXMLTextTests {
    private static func element(
        _ name: String, _ attributes: [String: String] = [:], _ content: [PreservedTextMarkup.ContentItem] = [],
    ) -> PreservedTextMarkup.ContentItem {
        .element(PreservedTextMarkup.Element(name: name, attributes: attributes, content: content))
    }

    /// Well-formed xml text in the spelling `xmlText` writes for the markup it reads as.
    private static let canonical = [
        "subito <sym>dynamicPiano</sym>",
        "<b>poco </b><sym>dynamicMezzo</sym><sym>dynamicForte</sym>",
        "<font face=\"Edwin\" size=\"12\"/>più",
        "a &amp; b &lt;c&gt;",
        "x<br/>y",
        "plain",
    ]

    @Test("markup is written as MuseScore xml text: characters escaped, an empty element self-closing")
    func writesXMLText() {
        let markup = PreservedTextMarkup(
            content: [
                .characters("subito "), Self.element("sym", [:], [.characters("dynamicPiano")]),
                Self.element("font", ["size": "12", "face": "Ed\"win"]), Self.element("i"),
                .characters(" 1 < 2 & 3 > 0"),
            ],
            derivedText: "subito  1 < 2 & 3 > 0",
        )
        #expect(markup.xmlText == "subito <sym>dynamicPiano</sym><font face=\"Ed&quot;win\" size=\"12\"/><i/>"
            + " 1 &lt; 2 &amp; 3 &gt; 0")
    }

    @Test("what is written reads back to the same text", arguments: canonical)
    func roundTrips(xmlText: String) {
        #expect(PreservedTextMarkup(xmlText: xmlText).xmlText == xmlText)
    }

    @Test("the markup read holds the runs RichText(xmlText:) reads from the same string", arguments: canonical)
    func readsLikeRichText(xmlText: String) {
        #expect(RichText(markup: PreservedTextMarkup(xmlText: xmlText)) == RichText(xmlText: xmlText))
    }

    @Test("the derived text is the plain projection: characters, no symbol names, entities decoded")
    func derivedTextIsThePlainProjection() {
        #expect(PreservedTextMarkup(xmlText: "subito <sym>dynamicPiano</sym>").derivedText == "subito ")
        #expect(PreservedTextMarkup(xmlText: "a &amp; b").derivedText == "a & b")
        #expect(PreservedTextMarkup(xmlText: "x<br/>y").derivedText == "x\ny")
    }

    @Test("broken markup is read as a reader recovers it: open tags close, a stray close is dropped")
    func toleratesBrokenMarkup() {
        #expect(PreservedTextMarkup(xmlText: "<b>bold").xmlText == "<b>bold</b>")
        #expect(PreservedTextMarkup(xmlText: "</i>text").content == [.characters("text")])
        #expect(PreservedTextMarkup(xmlText: "1 < 2").xmlText == "1 &lt; 2")
        #expect(PreservedTextMarkup(xmlText: "<b>a<i>b</b>c").xmlText == "<b>a<i>b</i></b>c")
        #expect(PreservedTextMarkup.escapedXMLText("a <b> & c") == "a &lt;b&gt; &amp; c")
    }

    private static func nesting(_ items: [PreservedTextMarkup.ContentItem]) -> Int {
        items.map { item in
            if case let .element(element) = item { 1 + nesting(element.content) } else { 0 }
        }.max() ?? 0
    }

    /// The text comes from a peer's edit or another app's pasteboard, so it is read as untrusted: nesting is bounded —
    /// the parse, `RichText(content:)` and the writer all recurse on it — and a name that is not a plain word is
    /// dropped, so what is saved inside `<text>` stays well-formed.
    @Test("untrusted xml text cannot nest without bound or name a malformed element or attribute")
    func untrustedTextIsBounded() {
        let deep = PreservedTextMarkup(xmlText: String(repeating: "<b>", count: 10000) + "x")
        #expect(Self.nesting(deep.content) == PreservedTextMarkup.maximumNesting)
        #expect(deep.derivedText == "x")
        #expect(PreservedTextMarkup(xmlText: #"<a"b>x</a"b>"#).xmlText == "x")
        let attribute = PreservedTextMarkup(xmlText: #"<font size="12" 1x="2">y</font>"#)
        #expect(attribute.xmlText == #"<font size="12">y</font>"#)
    }
}
