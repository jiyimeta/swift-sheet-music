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

    /// The absent case, asserted directly. Every encoder in the package calls
    /// `mscxTrailingChildren()` unconditionally, so "no color in, no `<color>`
    /// out" is what keeps ~27 call sites from writing a tag the source never
    /// had. Other suites cover it only as a side effect of exact-child-list
    /// assertions on elements that happen to be colorless; a claim about the
    /// absent case deserves a test whose input is the absent case.
    @Test func encodeNilColorEmitsNothing() {
        #expect(ElementProperties(color: nil).mscxTrailingChildren().isEmpty)
        #expect(ElementProperties.default.mscxTrailingChildren().isEmpty)
    }

    @Test func encodeColorEmitsOneRGBATag() {
        let out = ElementProperties(
            color: ScoreColor(red: 10, green: 20, blue: 30, alpha: 40),
        ).mscxTrailingChildren()
        #expect(out.count == 1)
        #expect(out.first?.name == "color")
        #expect(out.first?.attributes == ["r": "10", "g": "20", "b": "30", "a": "40"])
    }

    @Test func decodeMissingColorIsNil() {
        let node = XMLTreeNode(name: "Note")
        #expect(ElementProperties(decodingMSCXChildrenOf: node).color == nil)
    }

    @Test func decodeColorReadsRGBA() {
        let node = XMLTreeNode(
            name: "Note",
            children: [XMLTreeNode(
                name: "color",
                attributes: ["r": "255", "g": "0", "b": "0", "a": "255"],
            )],
        )
        let color = ElementProperties(decodingMSCXChildrenOf: node).color
        #expect(color == ScoreColor(red: 255, green: 0, blue: 0, alpha: 255))
    }

    @Test func decodeMissingOffsetIsNil() {
        let node = XMLTreeNode(name: "Note")
        #expect(ElementProperties(decodingMSCXChildrenOf: node).offset == nil)
    }

    @Test func decodeOffsetReadsSpatiumCoordinates() {
        let node = XMLTreeNode(
            name: "Note",
            children: [XMLTreeNode(
                name: "offset",
                attributes: ["x": "1.25", "y": "-2.5"],
            )],
        )
        let offset = ElementProperties(decodingMSCXChildrenOf: node).offset
        #expect(offset == ScoreOffset(x: 1.25, y: -2.5))
    }

    @Test func malformedOffsetCoordinatesFallBackWithoutLosingPresence() {
        let node = XMLTreeNode(
            name: "Note",
            children: [XMLTreeNode(
                name: "offset",
                attributes: ["x": "not-a-number"],
            )],
        )
        let offset = ElementProperties(decodingMSCXChildrenOf: node).offset
        #expect(offset == ScoreOffset(x: 0, y: 0))
    }

    @Test func encodeOffsetEmitsBothCoordinates() {
        let out = ElementProperties(
            offset: ScoreOffset(x: 1.25, y: -2.5),
        ).mscxChildren()
        #expect(out.count == 1)
        #expect(out.first?.name == "offset")
        #expect(out.first?.attributes["x"] == "1.25")
        #expect(out.first?.attributes["y"] == "-2.5")
    }

    @Test func explicitZeroStaffTextOffsetRoundTripsAsPresent() throws {
        let source = XMLTreeNode(
            name: "StaffText",
            children: [
                XMLTreeNode(name: "text", text: "zero"),
                XMLTreeNode(
                    name: "offset",
                    attributes: ["x": "0", "y": "0"],
                ),
            ],
        )
        let decoded = try StaffText.decode(source, isSystemText: false)
        #expect(decoded.elementProperties.offset == ScoreOffset(x: 0, y: 0))

        let encoded = decoded.encode()
        let offsets = encoded.all("offset")
        #expect(offsets.count == 1)
        #expect(offsets.first?.attributes["x"] == "0")
        #expect(offsets.first?.attributes["y"] == "0")

        let reparsed = try StaffText.decode(encoded, isSystemText: false)
        #expect(reparsed.elementProperties.offset == ScoreOffset(x: 0, y: 0))
    }
}
