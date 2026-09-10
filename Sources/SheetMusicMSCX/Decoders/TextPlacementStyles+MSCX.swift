import SheetMusicCore
import SheetMusicXMLTools

extension TextPlacementStyles {
    private static let fields: [(TextPlacementRole, String, String?)] = [
        (.lyrics, "lyrics", "lyricsPlacement"),
        (.staffText, "staffText", "staffTextPlacement"),
        (.systemText, "systemText", "systemTextPlacement"),
        (.rehearsalMark, "rehearsalMark", "rehearsalMarkPlacement"),
        (.harmonyA, "chordSymbolA", "harmonyPlacement"),
        (.harmonyB, "chordSymbolB", nil),
        (.romanNumeral, "romanNumeral", nil),
        (.nashvilleNumber, "nashvilleNumber", nil),
    ]

    static var consumedTags: Set<String> {
        Set(fields.flatMap { _, prefix, side in
            [prefix + "PosAbove", prefix + "PosBelow"] + (side.map { [$0] } ?? [])
        })
    }

    mutating func overlay(_ node: XMLTreeNode) {
        for (role, prefix, side) in Self.fields {
            var style = self[role]
            if let side, let node = node.first(side) {
                style.placement = Placement(rawValue: node.text)
            }
            if let node = node.first(prefix + "PosAbove") { style.positionAbove = Self.position(node) }
            if let node = node.first(prefix + "PosBelow") { style.positionBelow = Self.position(node) }
            self[role] = style
        }
    }

    private static func position(_ node: XMLTreeNode) -> ScoreOffset? {
        guard let x = node.attributes["x"].flatMap(Double.init), x.isFinite,
              let y = node.attributes["y"].flatMap(Double.init), y.isFinite else { return nil }
        return ScoreOffset(x: x, y: y)
    }

    func mscxChildren() -> [XMLTreeNode] {
        var children: [XMLTreeNode] = []
        for (role, prefix, side) in Self.fields {
            let style = self[role]
            if let side, let placement = style.placement {
                children.append(XMLTreeNode(name: side, text: placement.rawValue))
            }
            for (name, point) in [
                (prefix + "PosAbove", style.positionAbove),
                (prefix + "PosBelow", style.positionBelow),
            ] {
                guard let point, point.x.isFinite, point.y.isFinite else { continue }
                children.append(XMLTreeNode(name: name, attributes: ["x": String(point.x), "y": String(point.y)]))
            }
        }
        return children
    }
}
