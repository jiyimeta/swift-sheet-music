@testable import SheetMusicCore
@testable import SheetMusicMSCX
@testable import SheetMusicXMLTools
import Testing

@Suite("Element color MSCX write-back")
struct ElementColorMSCXWriteBackTests {
    private let expectedColor = ScoreColor(red: 10, green: 20, blue: 30, alpha: 40)
    private let expectedAttributes = ["r": "10", "g": "20", "b": "30", "a": "40"]

    private func colorNode() -> XMLTreeNode {
        XMLTreeNode(name: "color", attributes: expectedAttributes)
    }

    private func expectEncodedColor(in node: XMLTreeNode) throws {
        let colors = node.all("color")
        #expect(colors.count == 1)
        let color = try #require(colors.first)
        #expect(color.attributes == expectedAttributes)
    }

    @Test func chordOrnamentColorRoundTrips() throws {
        let ornament = ChordOrnament.decode(XMLTreeNode(
            name: "Ornament",
            children: [
                XMLTreeNode(name: "subtype", text: "ornamentTrill"),
                colorNode(),
            ],
        ))
        #expect(ornament.elementProperties.color == expectedColor)
        try expectEncodedColor(in: ornament.encode())
    }

    @Test func fingeringColorRoundTripsAfterModeledStyle() throws {
        let fingering = Fingering.decode(XMLTreeNode(
            name: "Fingering",
            children: [
                XMLTreeNode(name: "style", text: "guitar_fingering_lh"),
                colorNode(),
                XMLTreeNode(name: "text", text: "1"),
            ],
        ))
        #expect(fingering.elementProperties.color == expectedColor)

        let encoded = fingering.encode()
        #expect(encoded.children.map(\.name) == ["style", "text", "color"])
        try expectEncodedColor(in: encoded)
    }

    @Test func stickingColorRoundTripsAfterPreservedStyle() throws {
        let sticking = Sticking.decode(XMLTreeNode(
            name: "Sticking",
            children: [
                XMLTreeNode(name: "style", text: "sticking"),
                colorNode(),
                XMLTreeNode(name: "text", text: "R"),
            ],
        ))
        #expect(sticking.elementProperties.color == expectedColor)
        #expect(sticking.preservedMarkup.map(\.name) == ["style"])

        let encoded = sticking.encode()
        #expect(encoded.children.map(\.name) == ["text", "style", "color"])
        try expectEncodedColor(in: encoded)
    }

    @Test func expressionTextColorRoundTrips() throws {
        let expression = ExpressionText.decode(XMLTreeNode(
            name: "Expression",
            children: [colorNode(), XMLTreeNode(name: "text", text: "dolce")],
        ))
        #expect(expression.elementProperties.color == expectedColor)
        try expectEncodedColor(in: expression.encode())
    }

    @Test func chordBracketColorRoundTrips() throws {
        let bracketNode = XMLTreeNode(
            name: "ChordBracket",
            children: [colorNode()],
        )
        let chordNode = XMLTreeNode(name: "Chord", children: [bracketNode])
        let bracket = try #require(ChordBracket.decode(inChord: chordNode))
        #expect(bracket.elementProperties.color == expectedColor)
        try expectEncodedColor(in: bracket.encode())
    }

    @Test func engravingSymbolColorRoundTrips() throws {
        let symbolNode = XMLTreeNode(
            name: "Symbol",
            children: [XMLTreeNode(name: "name", text: "ornamentTrill"), colorNode()],
        )
        let noteNode = XMLTreeNode(name: "Note", children: [symbolNode])
        let symbol = try #require(EngravingSymbol.decodeAll(
            inNote: noteNode,
            excludingNames: [],
        ).first)
        #expect(symbol.elementProperties.color == expectedColor)
        try expectEncodedColor(in: symbol.encode())
    }

    @Test func harmonyColorRoundTrips() throws {
        let harmony = try Harmony.decode(XMLTreeNode(
            name: "Harmony",
            children: [
                XMLTreeNode(name: "name", text: "C"),
                colorNode(),
            ],
        ))
        #expect(harmony.elementProperties.color == expectedColor)
        try expectEncodedColor(in: harmony.encode())
    }

    @Test func baglessTypesEmitExactlyOneColor() {
        let staffText = StaffText(text: "text", color: expectedColor).encode()

        var tempo = Tempo(beatsPerSecond: 2)
        tempo.elementProperties.color = expectedColor

        let nodes = [
            staffText,
            tempo.encode(),
            Swing(color: expectedColor).encode(),
            InstrumentChange(text: "change", color: expectedColor).encode(),
            RehearsalMark(text: "A", color: expectedColor).encode(),
        ]
        let colorCounts = nodes.map { $0.all("color").count }
        #expect(colorCounts == [1, 1, 1, 1, 1])
        let colorAttributes = nodes.compactMap { $0.first("color")?.attributes }
        #expect(colorAttributes == [
            expectedAttributes,
            expectedAttributes,
            expectedAttributes,
            expectedAttributes,
            expectedAttributes,
        ])
    }
}
