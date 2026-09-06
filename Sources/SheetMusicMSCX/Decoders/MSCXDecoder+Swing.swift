import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Swing {
    /// Decode a `<StaffText>` / `<SystemText>` whose body contains an
    /// inline `<swing unit="eighth|16th|" ratio="N"/>` child. Caller
    /// should use `MSCXDecoder+Voice` to detect the marker child and
    /// route StaffText/SystemText elements through this initializer
    /// instead of `StaffText.decode(_:isSystemText:)`.
    ///
    /// Mirrors `read460/tread.cpp` swing-tag handling and
    /// `StaffTextBase`'s default `setSwingParameters(DIVISION/2, 60)`.
    static func decode(
        _ node: XMLTreeNode, isSystemText: Bool,
    ) -> Swing {
        let textNode = node.first("text")
        let text = textNode.map(StaffText.plainText(of:)) ?? ""
        let color = node.first("color").flatMap(StaffText.decodeColor(_:))
        let props = TextProperties.decode(node)
        // Swing marker child: `<swing unit="eighth|16th|" ratio="60"/>`.
        // Defaults match `StaffTextBase`'s constructor (eighth, 60).
        var unit: SwingUnit = .eighth
        var ratio = 60
        if let swingNode = node.first("swing") {
            let attrs = swingNode.attributes
            if let unitRaw = attrs["unit"],
               let parsed = SwingUnit(mscxString: unitRaw)
            {
                unit = parsed
            }
            if let ratioRaw = attrs["ratio"], let v = Int(ratioRaw) {
                ratio = v
            }
        }
        var swing = Swing(
            text: text,
            unit: unit,
            ratio: ratio,
            isSystemText: isSystemText,
            color: color,
            properties: props,
            preservedTextMarkup: textNode.flatMap(StaffText.preservedTextMarkup(of:)),
        )
        swing.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return swing
    }

    /// True when the given `<StaffText>` / `<SystemText>` node has a
    /// `<swing>` child — used by the voice decoder to dispatch to the
    /// `.swing` case instead of `.staffText`.
    static func isSwingMarker(_ node: XMLTreeNode) -> Bool {
        node.children.contains { $0.name == "swing" }
    }
}
