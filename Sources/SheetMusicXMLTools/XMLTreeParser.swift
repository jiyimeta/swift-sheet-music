import SheetMusicCore
import SheetMusicFoundation

/// Parses XML bytes into an in-memory `XMLTreeNode` tree.
///
/// A non-validating, namespace-unaware scanner written in pure Swift. It
/// replaces Foundation's `XMLParser`, whose `NSObject` delegate protocol pins
/// the whole `Foundation` umbrella (and with it ICU, worth ~10 MB in a
/// WebAssembly build) into targets that otherwise need only
/// `FoundationEssentials`.
///
/// Behaviour is matched to the previous implementation rather than to the XML
/// specification where the two differ, because MSCX export is covered by
/// byte-identical corpus gates:
///
/// - Namespaces are not processed, so `mei:note` stays a single verbatim name
///   and `xmlns` attributes are ordinary attributes.
/// - An element's `text` is the concatenation of *all* its direct character
///   data in document order, with child positions erased, trimmed once when
///   the element closes.
/// - Comments, processing instructions and the DOCTYPE are skipped silently.
public enum XMLTreeParser {
    /// Parse the given XML bytes into a single root `XMLTreeNode`.
    public static func parse(_ data: Data) throws -> XMLTreeNode {
        let bytes = [UInt8](data)
        var scanner = XMLScanner(bytes)
        do {
            if let bad = XMLScanner.firstInvalidUTF8(in: bytes) {
                throw scanner.error("input is not valid UTF-8", at: bad)
            }
            return try parseDocument(&scanner)
        } catch let error as XMLSyntaxError {
            throw SheetMusicError.invalidXML(underlying: error)
        }
    }

    private static func parseDocument(_ scanner: inout XMLScanner) throws -> XMLTreeNode {
        try skipProlog(&scanner)
        guard scanner.peek() == UInt8(ascii: "<") else {
            throw scanner.error("XML produced no root element")
        }
        let root = try parseElementTree(&scanner)
        try skipProlog(&scanner)
        guard scanner.isAtEnd else {
            throw scanner.error("unexpected content after the root element")
        }
        return root
    }

    /// Whitespace, comments, processing instructions (including the XML
    /// declaration) and the DOCTYPE, in any order.
    private static func skipProlog(_ scanner: inout XMLScanner) throws {
        while true {
            scanner.skipWhitespace()
            if scanner.matches(Token.commentOpen) {
                try skipComment(&scanner)
            } else if scanner.matches(Token.doctypeOpen) {
                try skipDoctype(&scanner)
            } else if scanner.matches(Token.piOpen) {
                try skipProcessingInstruction(&scanner)
            } else {
                return
            }
        }
    }

    // MARK: - Elements

    /// Iterative rather than recursive: a deep score must not be able to blow
    /// the stack, which on WebAssembly corrupts memory rather than trapping.
    private static func parseElementTree(_ scanner: inout XMLScanner) throws -> XMLTreeNode {
        var stack: [PartialNode] = []
        var finished: XMLTreeNode?

        while true {
            if scanner.isAtEnd {
                throw scanner.error("unexpected end of document inside an element")
            }

            if scanner.peek() == UInt8(ascii: "<") {
                if scanner.matches(Token.commentOpen) {
                    try skipComment(&scanner)
                } else if scanner.matches(Token.cdataOpen) {
                    guard !stack.isEmpty else {
                        throw scanner.error("character data outside the root element")
                    }
                    try scanCDATA(&scanner, into: &stack[stack.count - 1].text)
                } else if scanner.matches(Token.piOpen) {
                    try skipProcessingInstruction(&scanner)
                } else if scanner.matches(Token.endTagOpen) {
                    try closeElement(&scanner, stack: &stack, finished: &finished)
                    if stack.isEmpty { return try require(finished, scanner) }
                } else {
                    try openElement(&scanner, stack: &stack, finished: &finished)
                    if !stack.isEmpty { continue }
                    return try require(finished, scanner)
                }
            } else {
                guard !stack.isEmpty else {
                    throw scanner.error("character data outside the root element")
                }
                try scanCharacterData(&scanner, into: &stack[stack.count - 1].text)
            }
        }
    }

    private static func require(_ node: XMLTreeNode?, _ scanner: XMLScanner) throws -> XMLTreeNode {
        guard let node else { throw scanner.error("XML produced no root element") }
        return node
    }

    private static func openElement(
        _ scanner: inout XMLScanner, stack: inout [PartialNode], finished: inout XMLTreeNode?,
    ) throws {
        scanner.advance() // <
        let name = try scanner.scanName()
        let (attributes, isSelfClosing) = try scanAttributes(&scanner)

        if isSelfClosing {
            let node = XMLTreeNode(name: name, attributes: attributes)
            attach(node, stack: &stack, finished: &finished)
        } else {
            stack.append(PartialNode(name: name, attributes: attributes))
        }
    }

    private static func closeElement(
        _ scanner: inout XMLScanner, stack: inout [PartialNode], finished: inout XMLTreeNode?,
    ) throws {
        let start = scanner.index
        scanner.advance(2) // </
        let name = try scanner.scanName()
        scanner.skipWhitespace()
        guard scanner.peek() == UInt8(ascii: ">") else {
            throw scanner.error("malformed closing tag </\(name)")
        }
        scanner.advance()

        guard let open = stack.popLast() else {
            throw scanner.error("closing tag </\(name)> has no matching open tag", at: start)
        }
        guard open.name == name else {
            throw scanner.error(
                "closing tag </\(name)> does not match <\(open.name)>", at: start,
            )
        }
        let node = XMLTreeNode(
            name: open.name,
            attributes: open.attributes,
            text: trimmed(open.text),
            children: open.children,
        )
        attach(node, stack: &stack, finished: &finished)
    }

    private static func attach(
        _ node: XMLTreeNode, stack: inout [PartialNode], finished: inout XMLTreeNode?,
    ) {
        if stack.isEmpty {
            finished = node
        } else {
            stack[stack.count - 1].children.append(node)
        }
    }

    private static func scanAttributes(
        _ scanner: inout XMLScanner,
    ) throws -> (attributes: [String: String], isSelfClosing: Bool) {
        var attributes: [String: String] = [:]
        while true {
            scanner.skipWhitespace()
            guard let byte = scanner.peek() else {
                throw scanner.error("unexpected end of document inside a tag")
            }
            if byte == UInt8(ascii: ">") {
                scanner.advance()
                return (attributes, false)
            }
            if byte == UInt8(ascii: "/") {
                scanner.advance()
                guard scanner.peek() == UInt8(ascii: ">") else {
                    throw scanner.error("expected '>' after '/'")
                }
                scanner.advance()
                return (attributes, true)
            }

            let namePosition = scanner.index
            let name = try scanner.scanName()
            scanner.skipWhitespace()
            guard scanner.peek() == UInt8(ascii: "=") else {
                throw scanner.error("expected '=' after attribute \(name)")
            }
            scanner.advance()
            scanner.skipWhitespace()
            let value = try scanAttributeValue(&scanner)
            guard attributes.updateValue(value, forKey: name) == nil else {
                throw scanner.error("duplicate attribute \(name)", at: namePosition)
            }
        }
    }
}

/// An element whose end tag has not been seen yet.
private struct PartialNode {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [XMLTreeNode] = []
}

enum Token {
    static let commentOpen = [UInt8]("<!--".utf8)
    static let commentClose = [UInt8]("-->".utf8)
    static let cdataOpen = [UInt8]("<![CDATA[".utf8)
    static let cdataClose = [UInt8]("]]>".utf8)
    static let doctypeOpen = [UInt8]("<!DOCTYPE".utf8)
    static let piOpen = [UInt8]("<?".utf8)
    static let piClose = [UInt8]("?>".utf8)
    static let endTagOpen = [UInt8]("</".utf8)
}
