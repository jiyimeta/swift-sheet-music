import SheetMusicFoundation

/// Records character data and child elements in source order for an opted-in
/// subtree. The parser's default deliberately concatenates direct character
/// data and trims it once because MSCX's byte-identical gates depend on that
/// legacy behavior; this is the parallel representation for callers that need
/// the interleaving as well.
public enum XMLContentItem: Sendable, Equatable {
    case characters(String)
    case element(XMLTreeNode)
}

/// XML element tree that always preserves direct child-element order.
/// Character/element interleaving is preserved only for parse-opted-in
/// subtrees, where it is available in `mixedContent`.
/// Lightweight on purpose — callers walk it in per-target decoder extensions.
public struct XMLTreeNode: Sendable, Equatable {
    public let name: String
    public let attributes: [String: String]
    public var text: String
    public var children: [XMLTreeNode]
    /// The source-ordered content retained alongside legacy `text` and
    /// `children` when parsing opted into this subtree. It is `nil` outside
    /// those subtrees — for MSCX, everywhere except a `<text>` subtree — so
    /// default parsing keeps its established concatenate-then-trim behavior.
    public let mixedContent: [XMLContentItem]?

    public init(
        name: String,
        attributes: [String: String] = [:],
        text: String = "",
        children: [XMLTreeNode] = [],
        mixedContent: [XMLContentItem]? = nil,
    ) {
        self.name = name
        self.attributes = attributes
        self.text = text
        self.children = children
        self.mixedContent = mixedContent
    }

    /// First direct child element with this name, or nil.
    public func first(_ name: String) -> XMLTreeNode? {
        children.first(where: { $0.name == name })
    }

    /// All direct child elements with this name, in document order.
    public func all(_ name: String) -> [XMLTreeNode] {
        children.filter { $0.name == name }
    }
}
