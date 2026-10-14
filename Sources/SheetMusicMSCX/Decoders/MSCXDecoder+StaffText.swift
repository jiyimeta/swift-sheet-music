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

    /// The plain projection of a `<text>` subtree — what every text carrier stores as `text` and what its preserved
    /// markup's `derivedText` records: characters in source order, `<br/>` as a line break, `<sym>` contributing
    /// nothing (it is a glyph), formatting tags transparent (`RichText.plainText`). A `<text>` without child elements
    /// keeps the parser's trimmed character data, exactly as before, so unformatted text reads byte-identically.
    static func plainText(of node: XMLTreeNode) -> String {
        guard !node.children.isEmpty else { return node.text }
        return RichText(content: markupContent(of: node)).plainText
    }

    /// Capture a marked-up `<text>` subtree without allocating for the common plain-character case. The encoder
    /// re-emits it only while the model still holds `derivedText` (by default this subtree's `plainText(of:)`), so an
    /// edit drops stale formatting.
    static func preservedTextMarkup(of node: XMLTreeNode) -> PreservedTextMarkup? {
        preservedTextMarkup(of: node, derivedText: plainText(of: node))
    }

    static func preservedTextMarkup(
        of node: XMLTreeNode, derivedText: String,
    ) -> PreservedTextMarkup? {
        guard !node.children.isEmpty, let mixedContent = node.mixedContent else {
            return nil
        }
        return PreservedTextMarkup(
            content: mixedContent.map(preservedContent(_:)),
            derivedText: derivedText,
        )
    }

    /// `node`'s content as markup items: in source order when parsing kept it (`mixedContent`), otherwise in the
    /// legacy shape — own characters first, then each child.
    private static func markupContent(of node: XMLTreeNode) -> [PreservedTextMarkup.ContentItem] {
        preservedElement(node).content
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
