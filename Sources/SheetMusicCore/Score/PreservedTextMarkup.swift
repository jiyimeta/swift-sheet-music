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

    public init(content: [ContentItem]) {
        self.content = content
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
