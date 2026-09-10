@testable import SheetMusicCore
@testable import SheetMusicMSCX
import SheetMusicXMLTools
import Testing

@Suite("Text placement style MSCX")
struct TextPlacementStyleTests {
    @Test(arguments: [MSCXVersion.v3, .v4])
    func allRolesRoundTripWithoutPreservedDuplicates(version: MSCXVersion) {
        let prefixes = [
            "lyrics",
            "staffText",
            "systemText",
            "rehearsalMark",
            "chordSymbolA",
            "chordSymbolB",
            "romanNumeral",
            "nashvilleNumber",
        ]
        var children = prefixes.flatMap { prefix in
            [
                XMLTreeNode(name: prefix + "PosAbove", attributes: ["x": "1.25", "y": "-7.5"]),
                XMLTreeNode(name: prefix + "PosBelow", attributes: ["x": "2.25", "y": "8.5"]),
            ]
        }
        children += ["lyrics", "staffText", "systemText", "rehearsalMark", "harmony"].map {
            XMLTreeNode(name: $0 + "Placement", text: "below")
        }
        let style = ScoreStyle.decode(style: XMLTreeNode(name: "Style", children: children))
        #expect(style.preservedMarkup.isEmpty)
        for role in TextPlacementRole.allCases {
            #expect(style.textPlacement[role].positionAbove == ScoreOffset(x: 1.25, y: -7.5))
            #expect(style.textPlacement[role].positionBelow == ScoreOffset(x: 2.25, y: 8.5))
            #expect(style.textPlacement.side(for: role, element: .default) == .below)
        }
        let encoded = style.encode(options: MSCXEncoderOptions(targetVersion: version))
        let decoded = ScoreStyle.decode(style: encoded)
        #expect(decoded.textPlacement == style.textPlacement)
        #expect(decoded.encode(options: MSCXEncoderOptions(targetVersion: version)) == encoded)
        for node in children {
            #expect(encoded.all(node.name).count == 1)
        }
    }

    @Test func inlineOverlayAndInvalidOverridesUseDefaults() {
        let base = ScoreStyle.decode(style: XMLTreeNode(name: "Style", children: [
            XMLTreeNode(name: "staffTextPlacement", text: "below"),
            XMLTreeNode(name: "staffTextPosBelow", attributes: ["x": "2", "y": "8"]),
            XMLTreeNode(name: "chordSymbolBPosAbove", attributes: ["x": "0", "y": "-9"]),
        ]))
        let overlay = ScoreStyle.decode(style: XMLTreeNode(name: "Style", children: [
            XMLTreeNode(name: "staffTextPosBelow", attributes: ["x": "3", "y": "10"]),
        ]), base: base)
        #expect(overlay.textPlacement[.staffText].placement == .below)
        #expect(overlay.textPlacement[.staffText].positionBelow == ScoreOffset(x: 3, y: 10))
        #expect(overlay.textPlacement[.harmonyB] == base.textPlacement[.harmonyB])
        let invalid = ScoreStyle.decode(style: XMLTreeNode(name: "Style", children: [
            XMLTreeNode(name: "staffTextPlacement", text: "middle"),
            XMLTreeNode(name: "staffTextPosBelow", attributes: ["x": "nan", "y": "inf"]),
        ]), base: overlay)
        #expect(invalid.textPlacement[.staffText] == TextPlacementStyle())
        #expect(invalid.preservedMarkup.isEmpty)
    }

    @Test(arguments: ["Note", "Chord", "Lyrics", "StaffText", "RehearsalMark", "Harmony"])
    func autoplaceGenericRoundTrip(carrier: String) {
        let source = XMLTreeNode(name: carrier, children: [XMLTreeNode(name: "autoplace", text: "0")])
        let properties = ElementProperties(decodingMSCXChildrenOf: source)
        #expect(properties.autoplace == false)
        #expect(properties.mscxChildren().filter { $0.name == "autoplace" }.count == 1)
        #expect(ElementProperties(decodingMSCXChildrenOf: XMLTreeNode(
            name: carrier,
            children: properties.mscxChildren(),
        )) == properties)
        #expect(ElementProperties(decodingMSCXChildrenOf: XMLTreeNode(name: carrier)).autoplace == nil)
    }
}
