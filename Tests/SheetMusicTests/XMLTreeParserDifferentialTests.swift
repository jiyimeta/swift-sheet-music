import Foundation
@testable import SheetMusicCore
@testable import SheetMusicXMLTools
import Testing

/// `XMLTreeParser` was reimplemented in pure Swift to get `SheetMusicXMLTools`
/// off the `Foundation` umbrella. These tests hold it to the tree the previous
/// Foundation-backed implementation produced, which is what every MSCX and
/// MusicXML decoder — and the byte-identical export corpus gate — is written
/// against.
@Suite("XMLTreeParser matches the Foundation implementation")
struct XMLTreeParserDifferentialTests {
    // MARK: - Every fixture in the test bundle

    @Test("every XML fixture parses to an identical tree")
    func fixtureSweep() throws {
        let fixtures = try Self.xmlFixtures()
        // Guards against the sweep silently finding nothing if resource
        // bundling changes. 39 `.mscx` / `.musicxml` / `.xml` fixtures ship
        // today; the floor only needs to catch a collapse to zero.
        #expect(fixtures.count >= 39, "fixture sweep looks vacuous — found \(fixtures.count)")

        for fixture in fixtures {
            let reference: XMLTreeNode
            do {
                reference = try ReferenceXMLTreeParser.parse(fixture.data)
            } catch {
                Issue.record("reference parser rejected \(fixture.name)")
                continue
            }
            do {
                let actual = try XMLTreeParser.parse(fixture.data)
                #expect(actual == reference, "tree differs for \(fixture.name)")
            } catch {
                Issue.record("new parser rejected \(fixture.name): \(error)")
            }
        }
    }

    // `.mscz` / `.mxl` payloads reach the same parser once the ZIP reader has
    // unwrapped them, and the full suite already decodes those fixtures
    // end-to-end, so there is nothing this sweep would add.

    // MARK: - Adversarial inputs

    @Test("entity and whitespace handling matches the reference parser")
    func adversarialAgreement() throws {
        let inputs: [String] = [
            "<r>plain</r>",
            "<r></r>",
            "<r/>",
            "<r>   </r>",
            "<r>&amp;&lt;&gt;&quot;&apos;</r>",
            "<r>&#38;&#x26;&#x3c;</r>",
            "<r a=\"&amp;&quot;\" b='single'/>",
            "<r a = \"spaced\"/>",
            "<t>a <b>x</b> c</t>",
            "<t>a\r\nb</t>",
            "<t>a\rb</t>",
            "<t>a\nb</t>",
            "<r a=\"x\ty\"/>",
            "<r a=\"x\r\ny\"/>",
            "<r a=\"x&#x9;y\"/>",
            "<r a=\"x&#xA;y\"/>",
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><r>x</r>",
            "<?xml version=\"1.0\" standalone=\"no\"?><r>x</r>",
            "<!-- lead --><r>x</r><!-- trail -->",
            "<r><!-- inner -->x</r>",
            "<r><?target data?>x</r>",
            "<!DOCTYPE r SYSTEM \"r.dtd\"><r>x</r>",
            "<!DOCTYPE r PUBLIC \"-//X//DTD Y//EN\" \"http://example/y.dtd\"><r>x</r>",
            "<r>\u{3000}full width\u{3000}</r>",
            "<r>\u{00A0}nbsp\u{00A0}</r>",
            "<r>ピアノ — Étude</r>",
            "<r><![CDATA[raw <x> & ]]></r>",
            "<r>a<![CDATA[b]]>c</r>",
            "<r><x/><x/><y/></r>",
            "<r>\n  <x>1</x>\n  <x>2</x>\n</r>",
        ]

        for input in inputs {
            let data = Data(input.utf8)
            let reference = try ReferenceXMLTreeParser.parse(data)
            let actual = try XMLTreeParser.parse(data)
            #expect(actual == reference, "tree differs for \(input.debugDescription)")
        }
    }

    @Test("malformed inputs are rejected by both parsers")
    func malformedAgreement() {
        let inputs: [String] = [
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

        for input in inputs {
            let data = Data(input.utf8)
            let referenceRejected = (try? ReferenceXMLTreeParser.parse(data)) == nil
            let actualRejected = (try? XMLTreeParser.parse(data)) == nil
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

    private static func xmlFixtures() throws -> [Fixture] {
        try resourceFiles(withExtensions: ["mscx", "musicxml", "xml"]).map {
            try Fixture(name: $0.lastPathComponent, data: Data(contentsOf: $0))
        }
    }

    private static func resourceFiles(withExtensions extensions: Set<String>) throws -> [URL] {
        guard let root = Bundle.module.resourceURL else { return [] }
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
