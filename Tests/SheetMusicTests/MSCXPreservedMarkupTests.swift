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
}
