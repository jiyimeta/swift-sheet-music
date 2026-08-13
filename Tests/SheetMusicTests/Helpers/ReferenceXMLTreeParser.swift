import Foundation
#if canImport(FoundationXML)
    import FoundationXML
#endif
import SheetMusicXMLTools

/// The Foundation-backed `XMLTreeParser` implementation, verbatim, kept only as
/// the oracle for `XMLTreeParserDifferentialTests`.
///
/// Production dropped it so that `SheetMusicXMLTools` needs no `Foundation`
/// umbrella symbol (and therefore no ICU) in a WebAssembly build. The test
/// target still links full Foundation, so the comparison stays available on
/// Apple platforms.
enum ReferenceXMLTreeParser {
    struct ParseFailure: Error {}

    static func parse(_ data: Data) throws -> XMLTreeNode {
        let delegate = TreeBuildingDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        guard parser.parse(), let root = delegate.root else {
            throw ParseFailure()
        }
        return root
    }
}

private final class TreeBuildingDelegate: NSObject, XMLParserDelegate {
    var root: XMLTreeNode?
    var stack: [XMLTreeNode] = []
    var error: Error?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String],
    ) {
        let node = XMLTreeNode(name: elementName, attributes: attributeDict, text: "", children: [])
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
        qualifiedName qName: String?,
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
