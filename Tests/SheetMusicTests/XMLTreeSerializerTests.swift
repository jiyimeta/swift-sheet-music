import Foundation
@testable import SheetMusicXMLTools
import Testing

@Suite("XMLTreeSerializer")
struct XMLTreeSerializerTests {
    private func serialize(_ node: XMLTreeNode) -> String {
        String(data: XMLTreeSerializer.serialize(node), encoding: .utf8) ?? ""
    }

    @Test("self-closes empty leaves")
    func selfClosesEmptyLeaves() {
        let node = XMLTreeNode(name: "root", children: [
            XMLTreeNode(name: "empty"),
        ])
        let xml = serialize(node)
        #expect(xml.contains("<empty/>"))
    }

    @Test("inlines elements with text")
    func inlinesText() {
        let node = XMLTreeNode(name: "root", children: [
            XMLTreeNode(name: "value", text: "42"),
        ])
        let xml = serialize(node)
        #expect(xml.contains("<value>42</value>"))
    }

    @Test("escapes XML metacharacters in text")
    func escapesTextMetachars() {
        let node = XMLTreeNode(name: "t", text: "a < b & c > d")
        let xml = serialize(node)
        #expect(xml.contains("a &lt; b &amp; c &gt; d"))
    }

    /// XML 1.0 has no spelling at all for most C0 controls — not even a character reference — so the parser rejects
    /// them, and a score whose text carries one (a PDF's text layer can) was written as a file nothing could reopen.
    @Test("drops characters XML 1.0 cannot carry, so the output parses back")
    func dropsCharactersXMLCannotCarry() throws {
        let node = XMLTreeNode(name: "root", children: [
            XMLTreeNode(name: "text", text: "A\u{01}B\u{1F}C\u{FFFE}D\tE"),
            XMLTreeNode(name: "attr", attributes: ["v": "x\u{0B}y\u{FFFF}z"]),
            XMLTreeNode(name: "mixed", mixedContent: [.characters("m\u{08}n")]),
        ])
        let data = XMLTreeSerializer.serialize(node)
        let parsed = try XMLTreeParser.parse(data)
        #expect(parsed.first("text")?.text == "ABCD\tE")
        #expect(parsed.first("attr")?.attributes["v"] == "xyz")
        #expect(parsed.first("mixed")?.text == "mn")
    }

    @Test("escapes quote in attribute values")
    func escapesAttrQuote() {
        let node = XMLTreeNode(
            name: "t",
            attributes: ["msg": "say \"hi\""],
        )
        let xml = serialize(node)
        #expect(xml.contains("msg=\"say &quot;hi&quot;\""))
    }

    @Test("attributes appear in sorted key order")
    func attrSortStable() {
        let node = XMLTreeNode(
            name: "t",
            attributes: ["b": "2", "a": "1", "c": "3"],
        )
        let xml = serialize(node)
        let line = xml.split(separator: "\n").first(where: { $0.contains("<t ") })
        #expect(line?.contains("a=\"1\" b=\"2\" c=\"3\"") == true)
    }

    @Test("emits XML prolog")
    func prologPresent() {
        let xml = serialize(XMLTreeNode(name: "root"))
        #expect(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"))
    }

    @Test("round-trips through XMLTreeParser")
    func roundTripsViaParser() throws {
        let original = XMLTreeNode(
            name: "root",
            attributes: ["v": "1"],
            children: [
                XMLTreeNode(name: "a", text: "hello"),
                XMLTreeNode(name: "b", children: [
                    XMLTreeNode(name: "c", text: "x"),
                ]),
                XMLTreeNode(name: "empty"),
            ],
        )
        let bytes = XMLTreeSerializer.serialize(original)
        let reparsed = try XMLTreeParser.parse(bytes)
        #expect(reparsed == original)
    }

    @Test("serializes mixed content inline without changing whitespace")
    func serializesMixedContentInline() throws {
        let source = "<text> a&amp;<b><i>B</i></b> c<sym>segno</sym> </text>"
        let original = try XMLTreeParser.parse(
            Data(source.utf8),
            preservingMixedContentIn: ["text"],
        )

        let encoded = serialize(original)

        #expect(encoded == "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\(source)\n")
    }

    @Test("mixed content preserves character and element interleaving")
    func mixedContentPreservesInterleaving() throws {
        let original = try XMLTreeParser.parse(
            Data("<text>a<b>B</b>c</text>".utf8),
            preservingMixedContentIn: ["text"],
        )

        let encoded = serialize(original)

        #expect(encoded.contains("<text>a<b>B</b>c</text>"))
        #expect(!encoded.contains("<text>ac<b>B</b></text>"))
        #expect(!encoded.contains("<b>B</b>ac"))
    }

    @Test("mixed content preservation inherits through nested markup")
    func nestedMixedContentPreservesInterleaving() throws {
        let source = "<text>a<b>B<i>C</i>D</b>e</text>"
        let original = try XMLTreeParser.parse(
            Data(source.utf8),
            preservingMixedContentIn: ["text"],
        )

        let bytes = XMLTreeSerializer.serialize(original)
        let encoded = String(data: bytes, encoding: .utf8) ?? ""
        let reparsed = try XMLTreeParser.parse(
            bytes,
            preservingMixedContentIn: ["text"],
        )

        #expect(encoded == "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\(source)\n")
        #expect(reparsed == original)
    }

    @Test("parser round-trips its inline mixed-content output")
    func mixedContentRoundTripsViaParser() throws {
        let original = try XMLTreeParser.parse(
            Data("<text> a &amp; <b><i>B&lt;</i></b> tail </text>".utf8),
            preservingMixedContentIn: ["text"],
        )

        let bytes = XMLTreeSerializer.serialize(original)
        let reparsed = try XMLTreeParser.parse(
            bytes,
            preservingMixedContentIn: ["text"],
        )

        #expect(reparsed == original)
    }

    @Test("empty mixed content self-closes without swallowing significant space")
    func emptyMixedContentAndSignificantSpace() throws {
        let empty = XMLTreeNode(name: "text", mixedContent: [])
        let spaced = try XMLTreeParser.parse(
            Data("<text> </text>".utf8),
            preservingMixedContentIn: ["text"],
        )

        #expect(serialize(empty).contains("<text/>"))
        #expect(serialize(spaced).contains("<text> </text>"))
    }
}
