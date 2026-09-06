import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

/// Build the `<text>` child shared by MSCX text-bearing elements.
func encodeText(
    _ text: String,
    preservedTextMarkup: PreservedTextMarkup? = nil,
    options: MSCXEncoderOptions = .init(),
) -> XMLTreeNode {
    guard options.emitPreservedMarkup,
          let preservedTextMarkup,
          preservedTextMarkup.plainText == text
    else {
        return XMLTreeNode(name: "text", text: text)
    }
    let content = preservedTextMarkup.content.map(xmlContent(_:))
    return XMLTreeNode(
        name: "text",
        text: directCharacters(in: content),
        children: childElements(in: content),
        mixedContent: content,
    )
}

private func xmlContent(
    _ item: PreservedTextMarkup.ContentItem,
) -> XMLContentItem {
    switch item {
    case let .characters(characters):
        return .characters(characters)
    case let .element(element):
        return .element(xmlElement(element))
    }
}

private func xmlElement(
    _ element: PreservedTextMarkup.Element,
) -> XMLTreeNode {
    let content = element.content.map(xmlContent(_:))
    return XMLTreeNode(
        name: element.name,
        attributes: element.attributes,
        text: directCharacters(in: content),
        children: childElements(in: content),
        mixedContent: content,
    )
}

private func directCharacters(in content: [XMLContentItem]) -> String {
    var result = ""
    for item in content {
        if case let .characters(characters) = item {
            result += characters
        }
    }
    return result.trimmingWhitespaceAndNewlines()
}

private func childElements(in content: [XMLContentItem]) -> [XMLTreeNode] {
    content.compactMap { item -> XMLTreeNode? in
        if case let .element(element) = item {
            return element
        }
        return nil
    }
}
