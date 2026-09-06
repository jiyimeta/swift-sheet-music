import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension FretDiagram {
    /// Every direct `<FretDiagram>` child this decoder reads. The singular
    /// old-format `<string>` and `<barre>` children deliberately stay out and
    /// ride in preserved markup.
    private static let consumedChildren: Set = [
        "Harmony", "fretDiagram", "frets", "strings",
        "color", "offset", "placement", "visible",
    ]

    /// Decode one `<FretDiagram>` without throwing. A chord diagram is an
    /// embellishment, so unreadable numeric values fall back to neutral
    /// defaults and an unreadable nested harmony is dropped.
    static func decode(_ node: XMLTreeNode) -> FretDiagram {
        let contents = node.first("fretDiagram")
        var diagram = FretDiagram(
            stringCount: node.first("strings").flatMap { Int($0.text) } ?? 6,
            fretCount: node.first("frets").flatMap { Int($0.text) } ?? 5,
            strings: contents?.all("string").compactMap(decodeString) ?? [],
            barre: contents?.first("barre").map(decodeBarre),
            harmony: node.first("Harmony").flatMap { try? Harmony.decode($0) },
            preservedMarkup: node.preservedMarkup(consuming: consumedChildren),
        )
        diagram.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return diagram
    }

    private static func decodeString(_ node: XMLTreeNode) -> FretString? {
        let marker = node.all("marker").last.map { FretString.Marker(mscxToken: $0.text) }
        let dots = node.all("dot").map { dot in
            FretString.Dot(
                fret: dot.attributes["fret"].flatMap(Int.init) ?? 0,
                kind: FretString.Dot.Kind(mscxToken: dot.text),
            )
        }
        guard marker != nil || !dots.isEmpty else { return nil }
        return FretString(
            index: node.attributes["no"].flatMap(Int.init) ?? 0,
            marker: marker,
            dots: dots,
        )
    }

    private static func decodeBarre(_ node: XMLTreeNode) -> FretBarre {
        FretBarre(
            startString: node.attributes["start"].flatMap(Int.init) ?? -1,
            endString: node.attributes["end"].flatMap(Int.init) ?? -1,
            fret: Int(node.text) ?? 0,
        )
    }
}
