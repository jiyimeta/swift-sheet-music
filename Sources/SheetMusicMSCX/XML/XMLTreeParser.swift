import Foundation
import SheetMusicCore

/// Parses XML bytes into an in-memory `XMLNode` tree.
public enum XMLTreeParser {
    /// Parse the given XML bytes into a single root `XMLNode`.
    public static func parse(_ data: Data) throws -> XMLNode {
        let delegate = TreeBuildingDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        guard parser.parse() else {
            if let error = delegate.error {
                throw SheetMusicError.invalidXML(underlying: error)
            }
            if let parserError = parser.parserError {
                throw SheetMusicError.invalidXML(underlying: parserError)
            }
            throw SheetMusicError.invalidXML(
                underlying: NSError(domain: "XMLTreeParser", code: -1)
            )
        }
        guard let root = delegate.root else {
            throw SheetMusicError.malformedScore(reason: "XML produced no root element")
        }
        return root
    }
}

private final class TreeBuildingDelegate: NSObject, XMLParserDelegate {
    var root: XMLNode?
    var stack: [XMLNode] = []
    var error: Error?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        let node = XMLNode(name: elementName, attributes: attributeDict, text: "", children: [])
        stack.append(node)
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !stack.isEmpty else { return }
        stack[stack.count - 1].text.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        guard let finished = stack.popLast() else { return }
        var trimmed = finished
        trimmed.text = finished.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if stack.isEmpty {
            root = trimmed
        } else {
            stack[stack.count - 1].children.append(trimmed)
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        error = parseError
    }
}
