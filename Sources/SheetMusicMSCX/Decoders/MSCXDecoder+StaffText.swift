import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension StaffText {
    /// Decode a `<StaffText>` or `<SystemText>` element. Both share
    /// the same XML shape (`<text>`, optional `<color>`, optional
    /// `<offset>`); only `isSystemText` differs.
    static func decode(
        _ node: XMLTreeNode, isSystemText: Bool,
    ) throws -> StaffText {
        let text = node.first("text")
            .map(plainText(of:)) ?? ""
        let color = node.first("color").flatMap(decodeColor(_:))
        let offset = node.first("offset")
            .map(decodeOffset(_:)) ?? (0, 0)
        let props = TextProperties.decode(node)
        var staffText = StaffText(
            text: text,
            offsetX: offset.0,
            offsetY: offset.1,
            color: color,
            isSystemText: isSystemText,
            properties: props,
        )
        staffText.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return staffText
    }

    /// Recursively concatenate the text content of `node` and any
    /// nested elements. MuseScore wraps mixed-text values in inline
    /// HTML (e.g. `<font face="…"></font>`); the parsed tree puts
    /// loose character data on the parent's `text` and attaches
    /// inline tags as children, so we walk both. Order between text
    /// and child elements isn't preserved by `XMLTreeNode`, but
    /// `<StaffText>` author payloads almost always lead with
    /// formatting tags and follow with the actual text, so the
    /// concatenated result matches what the user sees.
    static func plainText(of node: XMLTreeNode) -> String {
        var result = node.text
        for child in node.children {
            result += plainText(of: child)
        }
        return result
    }

    static func decodeColor(
        _ node: XMLTreeNode,
    ) -> ScoreColor? {
        let attrs = node.attributes
        guard let r = attrs["r"].flatMap(Int.init),
              let g = attrs["g"].flatMap(Int.init),
              let b = attrs["b"].flatMap(Int.init)
        else { return nil }
        let a = attrs["a"].flatMap(Int.init) ?? 255
        return ScoreColor(red: r, green: g, blue: b, alpha: a)
    }

    static func decodeOffset(
        _ node: XMLTreeNode,
    ) -> (Double, Double) {
        let attrs = node.attributes
        let x = attrs["x"].flatMap(Double.init) ?? 0
        let y = attrs["y"].flatMap(Double.init) ?? 0
        return (x, y)
    }
}
