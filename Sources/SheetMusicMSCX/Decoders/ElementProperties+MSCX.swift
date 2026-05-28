import SheetMusicCore
import SheetMusicXMLTools

extension ElementProperties {
    /// Reads the base element properties (`<visible>`, future `<color>`, …)
    /// from an element node. Missing `<visible>` defaults to visible.
    init(decodingMSCXChildrenOf node: XMLTreeNode) {
        self.init(visible: (node.first("visible")?.text ?? "1") != "0")
    }

    /// Emits the base element child tags. `<visible>0</visible>` only when
    /// hidden (the default — visible — omits the tag, matching MuseScore).
    func mscxChildren() -> [XMLTreeNode] {
        var out: [XMLTreeNode] = []
        if !visible { out.append(XMLTreeNode(name: "visible", text: "0")) }
        return out
    }
}
