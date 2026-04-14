import Foundation
import SheetMusicCore

/// Order-preserving XML element tree built by `XMLTreeParser`.
/// Lightweight on purpose — we walk it in `MSCXDecoder+*` extensions.
public struct XMLNode: Sendable, Equatable {
    public let name: String
    public let attributes: [String: String]
    public var text: String
    public var children: [XMLNode]

    /// First direct child element with this name, or nil.
    public func first(_ name: String) -> XMLNode? {
        children.first(where: { $0.name == name })
    }

    /// All direct child elements with this name, in document order.
    public func all(_ name: String) -> [XMLNode] {
        children.filter { $0.name == name }
    }
}
