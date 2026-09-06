import SheetMusicFoundation

/// Opaque inline markup captured from a MuseScore `<text>` element.
///
/// This preserves XML structure for read → write fidelity only. Inline tags
/// such as `<font>` are state changes rather than necessarily being wrappers,
/// so no semantic text-run model is inferred from them.
/// `Hashable` because `FrameText` is, and a hand-written `hash(into:)` that
/// skipped this field would have to be revisited every time the struct grows
/// one — the kind of maintenance that silently goes stale.
public struct PreservedTextMarkup: Sendable, Equatable, Hashable {
    public enum ContentItem: Sendable, Equatable, Hashable {
        case characters(String)
        case element(Element)
    }

    public struct Element: Sendable, Equatable, Hashable {
        public let name: String
        public let attributes: [String: String]
        public let content: [ContentItem]

        public init(
            name: String,
            attributes: [String: String] = [:],
            content: [ContentItem] = [],
        ) {
            self.name = name
            self.attributes = attributes
            self.content = content
        }

        fileprivate var plainText: String {
            PreservedTextMarkup.plainText(of: content)
        }
    }

    public let content: [ContentItem]

    /// The plain text the decoder derived from this markup, recorded so the
    /// encoder can tell whether the model's text has moved since.
    ///
    /// It is supplied by the decoder rather than computed here because the
    /// decoders do not all flatten the same way: `StaffText` concatenates
    /// descendants, `Marker` reads only the `<text>` element's own character
    /// data, so `<text><sym>coda</sym></text>` is "coda" to one and "" to the
    /// other. Comparing against one global flattening would force every
    /// element onto the same convention — which is a modeling change, and a
    /// wrong one for `Marker`, whose plain text upstream is the glyph, not the
    /// SymId spelling.
    public let derivedText: String

    public init(content: [ContentItem], derivedText: String) {
        self.content = content
        self.derivedText = derivedText
    }

    /// The legacy decoder's flattening: trimmed direct character data first,
    /// followed by each child element's recursively flattened text.
    public var plainText: String {
        Self.plainText(of: content)
    }

    private static func plainText(of content: [ContentItem]) -> String {
        var characters = ""
        var descendants = ""
        for item in content {
            switch item {
            case let .characters(value):
                characters += value
            case let .element(element):
                descendants += element.plainText
            }
        }
        return characters.trimmingWhitespaceAndNewlines() + descendants
    }
}
