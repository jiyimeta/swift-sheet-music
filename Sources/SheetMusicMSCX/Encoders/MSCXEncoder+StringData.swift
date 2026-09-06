import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension StringData {
    /// Build the `<StringData>` element in MuseScore's storage order.
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        var children = [XMLTreeNode(name: "frets", text: String(frets))]
        for instrumentString in strings {
            var attributes: [String: String] = [:]
            if instrumentString.isOpen {
                attributes["open"] = "1"
            }
            if instrumentString.useFlat {
                attributes["useFlat"] = "1"
            }
            children.append(XMLTreeNode(
                name: "string",
                attributes: attributes,
                text: String(instrumentString.pitch),
            ))
        }
        appendPreservedMarkup(preservedMarkup, to: &children, options: options)
        return XMLTreeNode(name: "StringData", children: children)
    }
}
