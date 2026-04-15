import Foundation

/// Order-preserving XML element tree built by `XMLTreeParser`.
/// Lightweight on purpose — callers walk it in per-target decoder extensions.
public struct XMLTreeNode: Sendable, Equatable {
    public let name: String
    public let attributes: [String: String]
    public var text: String
    public var children: [XMLTreeNode]

    /// First direct child element with this name, or nil.
    public func first(_ name: String) -> XMLTreeNode? {
        children.first(where: { $0.name == name })
    }

    /// All direct child elements with this name, in document order.
    public func all(_ name: String) -> [XMLTreeNode] {
        children.filter { $0.name == name }
    }
}
