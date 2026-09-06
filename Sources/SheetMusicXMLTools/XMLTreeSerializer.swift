import SheetMusicFoundation

/// Serializes an `XMLTreeNode` tree to UTF-8 XML bytes.
///
/// Output is intentionally simple: 2-space indent, attributes in
/// sorted key order, self-closed empty leaves, standard prolog.
/// Byte-level parity with MuseScore Studio's writer is a non-goal —
/// the contract is that re-parsing the output via `XMLTreeParser`
/// reproduces the input tree.
public enum XMLTreeSerializer {
    public static func serialize(_ root: XMLTreeNode) -> Data {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        write(root, indent: 0, into: &out)
        return Data(out.utf8)
    }

    private static func write(
        _ node: XMLTreeNode, indent depth: Int, into out: inout String,
    ) {
        let pad = String(repeating: "  ", count: depth)
        if let mixedContent = node.mixedContent {
            writeMixedContentNode(
                node,
                content: mixedContent,
                pad: pad,
                into: &out,
            )
            return
        }
        let attrs = renderAttributes(node.attributes)
        let isEmpty = node.text.isEmpty && node.children.isEmpty
        if isEmpty {
            out += "\(pad)<\(node.name)\(attrs)/>\n"
            return
        }
        if node.children.isEmpty {
            out += "\(pad)<\(node.name)\(attrs)>\(escapeText(node.text))</\(node.name)>\n"
            return
        }
        out += "\(pad)<\(node.name)\(attrs)>\n"
        if !node.text.isEmpty {
            out += "\(pad)  \(escapeText(node.text))\n"
        }
        for child in node.children {
            write(child, indent: depth + 1, into: &out)
        }
        out += "\(pad)</\(node.name)>\n"
    }

    private static func writeMixedContentNode(
        _ node: XMLTreeNode,
        content: [XMLContentItem],
        pad: String,
        into out: inout String,
    ) {
        let attrs = renderAttributes(node.attributes)
        guard !content.isEmpty else {
            out += "\(pad)<\(node.name)\(attrs)/>\n"
            return
        }
        out += "\(pad)<\(node.name)\(attrs)>"
        writeInline(content, into: &out)
        out += "</\(node.name)>\n"
    }

    private static func writeInline(
        _ content: [XMLContentItem],
        into out: inout String,
    ) {
        for item in content {
            switch item {
            case let .characters(characters):
                out += escapeText(characters)
            case let .element(element):
                writeInline(element, into: &out)
            }
        }
    }

    private static func writeInline(
        _ node: XMLTreeNode,
        into out: inout String,
    ) {
        let attrs = renderAttributes(node.attributes)
        if let mixedContent = node.mixedContent {
            guard !mixedContent.isEmpty else {
                out += "<\(node.name)\(attrs)/>"
                return
            }
            out += "<\(node.name)\(attrs)>"
            writeInline(mixedContent, into: &out)
            out += "</\(node.name)>"
            return
        }
        guard !node.text.isEmpty || !node.children.isEmpty else {
            out += "<\(node.name)\(attrs)/>"
            return
        }
        out += "<\(node.name)\(attrs)>"
        out += escapeText(node.text)
        for child in node.children {
            writeInline(child, into: &out)
        }
        out += "</\(node.name)>"
    }

    private static func renderAttributes(_ attrs: [String: String]) -> String {
        guard !attrs.isEmpty else { return "" }
        var parts = ""
        for key in attrs.keys.sorted() {
            let value = attrs[key] ?? ""
            parts += " \(key)=\"\(escapeAttribute(value))\""
        }
        return parts
    }

    private static func escapeText(_ s: String) -> String {
        var r = ""
        r.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": r += "&amp;"
            case "<": r += "&lt;"
            case ">": r += "&gt;"
            default: r.append(ch)
            }
        }
        return r
    }

    private static func escapeAttribute(_ s: String) -> String {
        var r = ""
        r.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": r += "&amp;"
            case "<": r += "&lt;"
            case ">": r += "&gt;"
            case "\"": r += "&quot;"
            default: r.append(ch)
            }
        }
        return r
    }
}
