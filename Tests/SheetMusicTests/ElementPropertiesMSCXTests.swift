@testable import SheetMusicCore
@testable import SheetMusicMSCX
import SheetMusicXMLTools
import Testing

struct ElementPropertiesMSCXTests {
    @Test func decodeMissingVisibleIsTrue() {
        let node = XMLTreeNode(name: "Tempo")
        #expect(ElementProperties(decodingMSCXChildrenOf: node).visible == true)
    }

    @Test func decodeVisibleZeroIsFalse() {
        let node = XMLTreeNode(
            name: "Tempo",
            children: [XMLTreeNode(name: "visible", text: "0")],
        )
        #expect(ElementProperties(decodingMSCXChildrenOf: node).visible == false)
    }

    @Test func encodeVisibleTrueEmitsNothing() {
        #expect(ElementProperties(visible: true).mscxChildren().isEmpty)
    }

    @Test func encodeVisibleFalseEmitsTag() {
        let out = ElementProperties(visible: false).mscxChildren()
        #expect(out.count == 1)
        #expect(out.first?.name == "visible")
        #expect(out.first?.text == "0")
    }
}
