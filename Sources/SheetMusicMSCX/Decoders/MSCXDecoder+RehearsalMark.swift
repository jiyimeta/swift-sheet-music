import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension RehearsalMark {
    /// Decode a `<RehearsalMark>` voice child. Mirrors
    /// `MSCXDecoder+StaffText` for the `<text>` / `<color>` /
    /// `<offset>` shape (which `RehearsalMark` inherits from
    /// `TextBase` in MuseScore) and additionally reads `<frameType>`
    /// (0=rectangle, 1=circle, 2=none).
    static func decode(_ node: XMLTreeNode) throws -> RehearsalMark {
        let text = node.first("text").map(plainText(of:)) ?? ""
        let color = node.first("color").flatMap(decodeColor(_:))
        let offset = node.first("offset")
            .map(decodeOffset(_:)) ?? (0, 0)
        var props = TextProperties.decode(node)
        // RehearsalMark's per-element `frame` field already covers
        // `<frameType>`; lift it out of `properties` so callers can
        // keep using `mark.frame` directly. Default = SQUARE
        // (matches `Sid::rehearsalMarkFrameType`).
        let frame = props.frameType ?? .rectangle
        props.frameType = nil
        var mark = RehearsalMark(
            text: text,
            offsetX: offset.0,
            offsetY: offset.1,
            color: color,
            frame: frame,
            properties: props,
        )
        mark.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return mark
    }

    /// Recursively concatenate the text content, mirroring
    /// `StaffText.plainText(of:)` — MuseScore wraps mixed-text
    /// payloads in inline HTML (`<font>`, `<b>`) and the parsed
    /// tree puts loose character data on the parent's `text`
    /// while attaching inline tags as children.
    private static func plainText(of node: XMLTreeNode) -> String {
        var result = node.text
        for child in node.children {
            result += plainText(of: child)
        }
        return result
    }

    private static func decodeColor(
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

    private static func decodeOffset(
        _ node: XMLTreeNode,
    ) -> (Double, Double) {
        let attrs = node.attributes
        let x = attrs["x"].flatMap(Double.init) ?? 0
        let y = attrs["y"].flatMap(Double.init) ?? 0
        return (x, y)
    }
}
