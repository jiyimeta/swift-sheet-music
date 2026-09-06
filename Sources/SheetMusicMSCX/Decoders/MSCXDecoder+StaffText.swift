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
        let textNode = node.first("text")
        let text = textNode.map(plainText(of:)) ?? ""
        let color = node.first("color").flatMap(decodeColor(_:))
        let props = TextProperties.decode(node)
        var staffText = StaffText(
            text: text,
            color: color,
            isSystemText: isSystemText,
            properties: props,
            preservedTextMarkup: textNode.flatMap(preservedTextMarkup(of:)),
        )
        staffText.elementProperties = ElementProperties(decodingMSCXChildrenOf: node)
        return staffText
    }

    /// Reproduce the legacy plain-text projection: each element's trimmed
    /// direct character data followed by its child elements' projections.
    /// `mixedContent` now retains source interleaving separately, but the
    /// modeled `text` must keep this established value so existing decoders,
    /// edits, and preserve-if-equal checks agree.
    static func plainText(of node: XMLTreeNode) -> String {
        var result = node.text
        for child in node.children {
            result += plainText(of: child)
        }
        return result
    }

    /// Capture a marked-up `<text>` subtree without allocating for the common
    /// plain-character case.
    static func preservedTextMarkup(
        of node: XMLTreeNode,
    ) -> PreservedTextMarkup? {
        guard !node.children.isEmpty, let mixedContent = node.mixedContent else {
            return nil
        }
        return PreservedTextMarkup(
            content: mixedContent.map(preservedContent(_:)),
        )
    }

    private static func preservedContent(
        _ item: XMLContentItem,
    ) -> PreservedTextMarkup.ContentItem {
        switch item {
        case let .characters(characters):
            return .characters(characters)
        case let .element(element):
            return .element(preservedElement(element))
        }
    }

    private static func preservedElement(
        _ node: XMLTreeNode,
    ) -> PreservedTextMarkup.Element {
        let content: [PreservedTextMarkup.ContentItem]
        if let mixedContent = node.mixedContent {
            content = mixedContent.map(preservedContent(_:))
        } else {
            var legacyContent: [PreservedTextMarkup.ContentItem] = []
            if !node.text.isEmpty {
                legacyContent.append(.characters(node.text))
            }
            legacyContent += node.children.map { child -> PreservedTextMarkup.ContentItem in
                .element(preservedElement(child))
            }
            content = legacyContent
        }
        return PreservedTextMarkup.Element(
            name: node.name,
            attributes: node.attributes,
            content: content,
        )
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
}
