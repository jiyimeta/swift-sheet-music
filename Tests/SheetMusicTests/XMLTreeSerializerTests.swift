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

    @Test("escapes quote in attribute values")
    func escapesAttrQuote() {
        let node = XMLTreeNode(
            name: "t",
            attributes: ["msg": "say \"hi\""]
        )
        let xml = serialize(node)
        #expect(xml.contains("msg=\"say &quot;hi&quot;\""))
    }

    @Test("attributes appear in sorted key order")
    func attrSortStable() {
        let node = XMLTreeNode(
            name: "t",
            attributes: ["b": "2", "a": "1", "c": "3"]
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
            ]
        )
        let bytes = XMLTreeSerializer.serialize(original)
        let reparsed = try XMLTreeParser.parse(bytes)
        #expect(reparsed == original)
    }
}
