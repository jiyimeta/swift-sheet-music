import Foundation
@testable import SheetMusicCore
@testable import SheetMusicXMLTools
import Testing

/// `XMLTreeParser` was reimplemented in pure Swift to get `SheetMusicXMLTools`
/// off the `Foundation` umbrella. Checked-in `XMLTreeNode` expectations are the
/// portable specification; the FoundationXML oracle remains a corroborating
/// historical reference only where its platform behavior is trustworthy.
@Suite("XMLTreeParser matches checked-in XML tree expectations")
struct XMLTreeParserDifferentialTests {
    private static let adversarialCases: [(input: String, expected: XMLTreeNode)] = [
        ("<r>plain</r>", XMLTreeNode(name: "r", text: "plain")),
        ("<r></r>", XMLTreeNode(name: "r")),
        ("<r/>", XMLTreeNode(name: "r")),
        ("<r>   </r>", XMLTreeNode(name: "r")),
        ("<r>&amp;&lt;&gt;&quot;&apos;</r>", XMLTreeNode(name: "r", text: "&<>\"'")),
        ("<r>&#38;&#x26;&#x3c;</r>", XMLTreeNode(name: "r", text: "&&<")),
        (
            "<r a=\"&amp;&quot;\" b='single'/>",
            XMLTreeNode(name: "r", attributes: ["a": "&\"", "b": "single"]),
        ),
        ("<r a = \"spaced\"/>", XMLTreeNode(name: "r", attributes: ["a": "spaced"])),
        (
            "<t>a <b>x</b> c</t>",
            XMLTreeNode(
                name: "t",
                text: "a  c",
                children: [XMLTreeNode(name: "b", text: "x")],
            ),
        ),
        ("<t>a\r\nb</t>", XMLTreeNode(name: "t", text: "a\nb")),
        ("<t>a\rb</t>", XMLTreeNode(name: "t", text: "a\nb")),
        ("<t>a\nb</t>", XMLTreeNode(name: "t", text: "a\nb")),
        ("<r a=\"x\ty\"/>", XMLTreeNode(name: "r", attributes: ["a": "x y"])),
        ("<r a=\"x\r\ny\"/>", XMLTreeNode(name: "r", attributes: ["a": "x y"])),
        ("<r a=\"x&#x9;y\"/>", XMLTreeNode(name: "r", attributes: ["a": "x\ty"])),
        ("<r a=\"x&#xA;y\"/>", XMLTreeNode(name: "r", attributes: ["a": "x\ny"])),
        ("<?xml version=\"1.0\" encoding=\"UTF-8\"?><r>x</r>", XMLTreeNode(name: "r", text: "x")),
        ("<?xml version=\"1.0\" standalone=\"no\"?><r>x</r>", XMLTreeNode(name: "r", text: "x")),
        ("<!-- lead --><r>x</r><!-- trail -->", XMLTreeNode(name: "r", text: "x")),
        ("<r><!-- inner -->x</r>", XMLTreeNode(name: "r", text: "x")),
        ("<r><?target data?>x</r>", XMLTreeNode(name: "r", text: "x")),
        ("<!DOCTYPE r SYSTEM \"r.dtd\"><r>x</r>", XMLTreeNode(name: "r", text: "x")),
        (
            "<!DOCTYPE r PUBLIC \"-//X//DTD Y//EN\" \"http://example/y.dtd\"><r>x</r>",
            XMLTreeNode(name: "r", text: "x"),
        ),
        ("<r>\u{3000}full width\u{3000}</r>", XMLTreeNode(name: "r", text: "full width")),
        ("<r>\u{00A0}nbsp\u{00A0}</r>", XMLTreeNode(name: "r", text: "nbsp")),
        ("<r>ピアノ — Étude</r>", XMLTreeNode(name: "r", text: "ピアノ — Étude")),
        ("<r><![CDATA[raw <x> & ]]></r>", XMLTreeNode(name: "r", text: "raw <x> &")),
        ("<r>a<![CDATA[b]]>c</r>", XMLTreeNode(name: "r", text: "abc")),
        (
            "<r><x/><x/><y/></r>",
            XMLTreeNode(
                name: "r",
                children: [
                    XMLTreeNode(name: "x"),
                    XMLTreeNode(name: "x"),
                    XMLTreeNode(name: "y"),
                ],
            ),
        ),
        (
            "<r>\n  <x>1</x>\n  <x>2</x>\n</r>",
            XMLTreeNode(
                name: "r",
                children: [
                    XMLTreeNode(name: "x", text: "1"),
                    XMLTreeNode(name: "x", text: "2"),
                ],
            ),
        ),
    ]

    private static let malformedInputs: [String] = [
        "",
        "   ",
        "not xml",
        "<root><unclosed></root>",
        "<root>",
        "<root></wrong>",
        "<root/><second/>",
        "<root>&</root>",
        "<root>&undefined;</root>",
        "<root>&amp</root>",
        "<root a=unquoted/>",
        "<root a=\"x\" a=\"y\"/>",
        "<root>&#0;</root>",
        "<root><!-- unterminated </root>",
        "<root>]]></root>",
    ]

    // MARK: - Every fixture in the test bundle

    @Test("every XML fixture parses to an identical tree")
    func fixtureSweep() throws {
        let fixtures = try Self.xmlFixtures()
        // Guards against the sweep silently finding nothing if resource
        // bundling changes. 39 `.mscx` / `.musicxml` / `.xml` fixtures ship
        // today; the floor only needs to catch a collapse to zero.
        #expect(fixtures.count >= 39, "fixture sweep looks vacuous — found \(fixtures.count)")

        for fixture in fixtures {
            let actual = try XMLTreeParser.parse(fixture.data)
            // On wasm, this sweep still proves every XML fixture parses. Its
            // tree parity check is intentionally limited to platforms with the
            // trusted FoundationXML reference oracle.
            guard foundationXMLReferenceOracleAvailable else { continue }

            let reference: XMLTreeNode
            do {
                reference = try ReferenceXMLTreeParser.parse(fixture.data)
            } catch {
                Issue.record("reference parser rejected \(fixture.name)")
                continue
            }
            #expect(actual == reference, "tree differs for \(fixture.name)")
        }
    }

    // `.mscz` / `.mxl` payloads reach the same parser once the ZIP reader has
    // unwrapped them, and the full suite already decodes those fixtures
    // end-to-end, so there is nothing this sweep would add.

    // MARK: - Adversarial inputs

    @Test("adversarial corpus matches checked-in tree expectations")
    func adversarialAgreement() throws {
        for (input, expected) in Self.adversarialCases {
            let data = Data(input.utf8)
            let actual = try XMLTreeParser.parse(data)
            #expect(actual == expected, "tree differs from expected for \(input.debugDescription)")

            guard foundationXMLReferenceOracleAvailable else { continue }
            let reference = try ReferenceXMLTreeParser.parse(data)
            #expect(actual == reference, "tree differs for \(input.debugDescription)")
        }
    }

    @Test("malformed inputs are rejected by both parsers")
    func malformedAgreement() {
        for input in Self.malformedInputs {
            let data = Data(input.utf8)
            let actualRejected = (try? XMLTreeParser.parse(data)) == nil
            #expect(actualRejected, "\(input.debugDescription): new parser accepted malformed input")
            guard foundationXMLReferenceOracleAvailable else { continue }
            let referenceRejected = (try? ReferenceXMLTreeParser.parse(data)) == nil
            let detail = "\(input.debugDescription): reference=\(referenceRejected) "
                + "new=\(actualRejected)"
            #expect(referenceRejected == actualRejected, "\(detail)")
        }
    }

    @Test("invalid UTF-8 is rejected")
    func invalidUTF8() {
        let data = Data([0x3C, 0x72, 0x3E, 0xFF, 0xFE, 0x3C, 0x2F, 0x72, 0x3E]) // <r>\xFF\xFE</r>
        #expect((try? XMLTreeParser.parse(data)) == nil)
    }

    @Test("syntax errors report a position")
    func errorPosition() {
        let data = Data("<a>\n  <b></c>\n</a>".utf8)
        do {
            _ = try XMLTreeParser.parse(data)
            Issue.record("expected a parse failure")
        } catch let SheetMusicError.invalidXML(underlying) {
            let syntax = underlying as? XMLSyntaxError
            #expect(syntax?.line == 2)
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    // MARK: - Fixture discovery

    private struct Fixture {
        let name: String
        let data: Data
    }

    private var foundationXMLReferenceOracleAvailable: Bool {
        #if SHEET_MUSIC_HAS_FOUNDATION_XML_REFERENCE_ORACLE
            true
        #else
            false
        #endif
    }

    private static func xmlFixtures() throws -> [Fixture] {
        try resourceFiles(withExtensions: ["mscx", "musicxml", "xml"]).map {
            try Fixture(name: $0.lastPathComponent, data: Data(contentsOf: $0))
        }
    }

    private static func resourceFiles(withExtensions extensions: Set<String>) throws -> [URL] {
        guard let root = TestResources.resourceURL else { return [] }
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys,
        ) else { return [] }

        var found: [URL] = []
        for case let url as URL in walker where extensions.contains(url.pathExtension) {
            found.append(url)
        }
        return found.sorted { $0.path < $1.path }
    }
}
