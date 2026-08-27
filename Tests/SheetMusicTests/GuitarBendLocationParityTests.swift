import Foundation
@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// The gate on the `<location>` payloads themselves — which chord, grace or
/// note each side of a `<Spanner type="GuitarBend">` names.
///
/// Nothing else in the suite can see them. The decoder reads only whether a
/// `<next>` / `<prev>` child exists (`MSCXDecoder+Note.swift`, `decodeConnectors`)
/// and never looks inside `<location>`, so `parse(encode(x))` preserves
/// `guitarBend` / `guitarBendBack` whatever the location says — the model
/// round-trip in `GuitarBendRoundTripTests` is structurally blind here. A
/// document-wide `text.contains("<grace>0</grace>")` is barely better: it
/// cannot say which spanner the value came from, which side it sat on, or how
/// many were written, so emitting every right value on the wrong side would
/// still read green.
///
/// So this compares structurally and position by position: every
/// `<Spanner type="GuitarBend">` subtree of the re-encode against the same
/// subtree of the vendored MuseScore Studio file, in document order, with
/// `<eid>` stripped — MuseScore's own element identity, which this project
/// deliberately does not model or write. Everything else must match exactly,
/// which pins the `<GuitarBend>` payload (type, time factors, `<anchor>3</anchor>`,
/// `<GuitarBendHold>`) as well as the locations.
///
/// The per-fixture spanner counts are asserted on *both* sides so the
/// comparison cannot pass by both walks finding nothing; they were counted out
/// of the files (`grep -c 'Spanner type="GuitarBend"'`).
@Suite("GuitarBend location parity")
struct GuitarBendLocationParityTests {
    struct Fixture: Sendable, CustomStringConvertible {
        var name: String
        var spannerCount: Int

        var description: String {
            "\(name) (\(spannerCount) spanners)"
        }
    }

    static let fixtures = [
        Fixture(name: "guitarbend_simple", spannerCount: 6),
        Fixture(name: "guitarbend_prebend", spannerCount: 10),
        Fixture(name: "guitarbend_slightbend", spannerCount: 6),
        Fixture(name: "guitarbend_gracebend", spannerCount: 6),
        Fixture(name: "guitarbend_release_twice", spannerCount: 8),
        Fixture(name: "guitarbend_tied", spannerCount: 4),
    ]

    @Test(
        "re-encoded bend spanners match MuseScore's own, block for block",
        arguments: fixtures,
    )
    func spannerParity(fixture: Fixture) throws {
        let vendored = try MSCXFixtureLoader.mscxData(fixture.name)
        let reEncoded = try MSCXEncoder.encode(MSCXParser.parse(vendored))

        let expected = try Self.bendSpanners(in: vendored)
        let actual = try Self.bendSpanners(in: reEncoded)

        #expect(expected.count == fixture.spannerCount)
        #expect(actual.count == fixture.spannerCount)
        // Compared element-wise first: a whole-array mismatch prints two walls
        // of nested XML, whereas this names the spanner that drifted.
        for (index, pair) in zip(actual, expected).enumerated() {
            #expect(pair.0 == pair.1, "spanner \(index) of \(fixture.name)")
        }
        #expect(actual == expected)
    }

    // MARK: - Helpers

    /// An XML subtree reduced to what this project claims to reproduce: element
    /// name, text, and children, with `<eid>` dropped at every level.
    private struct CanonicalNode: Equatable, CustomStringConvertible {
        var name: String
        var text: String
        var children: [CanonicalNode]

        var description: String {
            let inner = children.map(\.description).joined(separator: " ")
            if children.isEmpty {
                return text.isEmpty ? "<\(name)/>" : "<\(name)>\(text)</\(name)>"
            }
            return "<\(name)>\(inner)</\(name)>"
        }
    }

    /// Every `<Spanner type="GuitarBend">` in the document, in document order.
    ///
    /// `XMLTreeParser` already trims each element's character data
    /// (`XMLTreeParser.swift:150`), so MuseScore's indented
    /// `<location>` + newline + `</location>` and this encoder's self-closing
    /// `<location/>` both arrive with empty text and no children — they
    /// compare equal without any normalization here.
    private static func bendSpanners(in data: Data) throws -> [CanonicalNode] {
        var result: [CanonicalNode] = []
        try collectBendSpanners(XMLTreeParser.parse(data), into: &result)
        return result
    }

    private static func collectBendSpanners(
        _ node: XMLTreeNode,
        into result: inout [CanonicalNode],
    ) {
        if node.name == "Spanner", node.attributes["type"] == "GuitarBend" {
            result.append(canonical(node))
            return
        }
        for child in node.children {
            collectBendSpanners(child, into: &result)
        }
    }

    private static func canonical(_ node: XMLTreeNode) -> CanonicalNode {
        CanonicalNode(
            name: node.name,
            text: node.text,
            children: node.children
                .filter { $0.name != "eid" }
                .map(canonical),
        )
    }
}
