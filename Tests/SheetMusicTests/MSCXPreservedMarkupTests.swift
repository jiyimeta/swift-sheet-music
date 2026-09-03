import Foundation
import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

/// The capture / restore primitives behind preserved markup.
///
/// The end-to-end property — "a fixture loses nothing on decode →
/// encode" — lives in `MSCXPreservationGateTests`. These pin the
/// pieces that gate depends on, so a failure there can be told apart
/// from a failure here.
@Suite("MSCX preserved markup primitives")
struct MSCXPreservedMarkupTests {
    @Test("consumed children are not preserved")
    func skipsConsumed() {
        let node = XMLTreeNode(name: "Chord", children: [
            XMLTreeNode(name: "durationType", text: "quarter"),
            XMLTreeNode(name: "StemDirection", text: "up"),
        ])
        let kept = node.preservedMarkup(consuming: ["durationType"])
        #expect(kept.map(\.name) == ["StemDirection"])
        #expect(kept.first?.text == "up")
    }

    @Test("source order is kept")
    func keepsOrder() {
        let node = XMLTreeNode(name: "Score", children: [
            XMLTreeNode(name: "Order"),
            XMLTreeNode(name: "Division", text: "480"),
            XMLTreeNode(name: "Synthesizer"),
        ])
        #expect(
            node.preservedMarkup(consuming: ["Division"]).map(\.name)
                == ["Order", "Synthesizer"],
        )
    }

    @Test("eid and the other never-preserved tags are dropped")
    func dropsExcluded() {
        let node = XMLTreeNode(name: "Chord", children: [
            XMLTreeNode(name: "eid", text: "abc"),
            XMLTreeNode(name: "StemDirection", text: "up"),
        ])
        #expect(node.preservedMarkup(consuming: []).map(\.name) == ["StemDirection"])
    }

    @Test("nested subtrees survive the round trip through PreservedXML")
    func nestedRoundTrip() {
        let source = XMLTreeNode(name: "Instrument", children: [
            XMLTreeNode(name: "StringData", children: [
                XMLTreeNode(name: "frets", text: "19"),
                XMLTreeNode(name: "string", attributes: ["l": "0"], text: "40"),
            ]),
        ])
        let kept = source.preservedMarkup(consuming: [])
        #expect(kept.count == 1)
        #expect(XMLTreeNode(preserved: kept[0]) == source.children[0])
    }

    @Test("<Order> and <showFrames> survive decode → encode")
    func scoreLevelUnknownSubtreesSurvive() throws {
        let source = try MSCXFixtureLoader.mscxData("grace_after")
        let encoded = try MSCXEncoder.encode(MSCXParser.parse(source))
        let root = try XMLTreeParser.parse(encoded)
        let score = try #require(root.first("Score"))
        let order = score.first("Order")
        let showFrames = score.first("showFrames")
        #expect(order != nil)
        #expect(showFrames != nil)
    }

    @Test("emitPreservedMarkup: false leaves preserved markup out")
    func preservedMarkupCanBeSuppressed() throws {
        let source = try MSCXFixtureLoader.mscxData("grace_after")
        var options = MSCXEncoderOptions()
        options.emitPreservedMarkup = false
        let encoded = try MSCXEncoder.encode(MSCXParser.parse(source), options: options)
        let root = try XMLTreeParser.parse(encoded)
        let score = try #require(root.first("Score"))
        let order = score.first("Order")
        let showFrames = score.first("showFrames")
        #expect(order == nil)
        #expect(showFrames == nil)
    }

    @Test("strippingPreservedMarkup clears it")
    func strippingClearsPreservedMarkup() throws {
        let source = try MSCXFixtureLoader.mscxData("grace_after")
        let stripped = try MSCXParser.parse(source).strippingPreservedMarkup()
        #expect(stripped.preservedMarkup.isEmpty)
        #expect(stripped.style.preservedMarkup.isEmpty)
    }

    /// A tag that appears both in a node's preserved markup and in
    /// the children the encoder writes means the decoder read it but
    /// its consumed set does not list it. The emit helper quietly
    /// drops that duplicate, so the preservation and idempotency
    /// gates cannot expose the drift; this test compares against an
    /// encode with preserved markup disabled so it can.
    @Test("no preserved tag collides with one the encoder writes")
    func preservedNamesNeverCollide() throws {
        for url in MSCXFixtureLoader.allMSCXURLs() {
            guard let score = try? MSCXParser.parse(Data(contentsOf: url)) else { continue }
            var options = MSCXEncoderOptions()
            options.emitPreservedMarkup = false
            let root = try score.encode(options: options)
            let encodedScore = try #require(root.first("Score"))

            let scoreNames = Set(score.preservedMarkup.map(\.name))
            let writtenScoreNames = Set(encodedScore.children.map(\.name))
            let scoreCollisions = scoreNames.intersection(writtenScoreNames).sorted()
            #expect(
                scoreCollisions.isEmpty,
                Comment(
                    rawValue: "\(url.lastPathComponent): <Score> writes \(scoreCollisions) and also "
                        + "preserves them — add them to the decoder's consumed set",
                ),
            )

            let styleNames = Set(score.style.preservedMarkup.map(\.name))
            let writtenStyleNames = Set(encodedScore.first("Style")?.children.map(\.name) ?? [])
            let styleCollisions = styleNames.intersection(writtenStyleNames).sorted()
            #expect(
                styleCollisions.isEmpty,
                Comment(
                    rawValue: "\(url.lastPathComponent): <Style> writes \(styleCollisions) and also "
                        + "preserves them — add them to the decoder's consumed set",
                ),
            )
        }
    }
}
