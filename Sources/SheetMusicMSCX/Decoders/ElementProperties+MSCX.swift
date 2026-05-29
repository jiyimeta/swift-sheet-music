import SheetMusicCore
import SheetMusicXMLTools

extension ElementProperties {
    /// Reads the base element properties (`<visible>`, `<color>`, …)
    /// from an element node. Missing `<visible>` defaults to visible;
    /// missing `<color>` (or malformed attributes) leaves color nil.
    init(decodingMSCXChildrenOf node: XMLTreeNode) {
        self.init(
            visible: (node.first("visible")?.text ?? "1") != "0",
            color: node.first("color").flatMap(StaffText.decodeColor(_:)),
        )
    }

    /// Emits the base element child tags. `<visible>0</visible>` only when
    /// hidden (the default — visible — omits the tag, matching MuseScore).
    ///
    /// `<color>` is intentionally NOT emitted here: the elements that
    /// currently persist color (RehearsalMark, Harmony, StaffText, Swing)
    /// own a dedicated `<color>` field and emit it themselves, so emitting
    /// it again from the shared base would double the tag. `color` here is
    /// decode-only for now — round-tripping notehead / rest / lyric color
    /// on MSCX export is a follow-up that should migrate those four to
    /// `elementProperties.color` first.
    func mscxChildren() -> [XMLTreeNode] {
        var out: [XMLTreeNode] = []
        if !visible { out.append(XMLTreeNode(name: "visible", text: "0")) }
        return out
    }
}
