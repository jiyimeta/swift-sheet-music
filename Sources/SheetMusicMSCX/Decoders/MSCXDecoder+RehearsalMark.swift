import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension RehearsalMark {
    /// Decode a `<RehearsalMark>` voice child. Mirrors
    /// `MSCXDecoder+StaffText` for the `<text>` / `<color>` /
    /// `<offset>` shape (which `RehearsalMark` inherits from
    /// `TextBase` in MuseScore) and additionally reads `<frameType>`
    /// (0=rectangle, 1=circle, 2=none).
    static func decode(_ node: XMLTreeNode) throws -> RehearsalMark {
        let textNode = node.first("text")
        let text = textNode.map(StaffText.plainText(of:)) ?? ""
        let color = node.first("color").flatMap(decodeColor(_:))
        var props = TextProperties.decode(node)
        // RehearsalMark's per-element `frame` field already covers
        // `<frameType>`; lift it out of `properties` so callers can
        // keep using `mark.frame` directly. Default = SQUARE
        // (matches `Sid::rehearsalMarkFrameType`).
        let frame = props.frameType ?? .rectangle
        props.frameType = nil
        var mark = RehearsalMark(
            text: text,
            color: color,
            frame: frame,
            properties: props,
            preservedTextMarkup: textNode.flatMap(StaffText.preservedTextMarkup(of:)),
        )
        mark.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return mark
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
}
