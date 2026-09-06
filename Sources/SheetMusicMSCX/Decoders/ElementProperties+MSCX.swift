import SheetMusicCore
import SheetMusicXMLTools

extension ElementProperties {
    /// Reads the base element properties (`<visible>`, `<color>`, `<offset>`, …)
    /// from an element node. Missing `<visible>` defaults to visible;
    /// missing `<color>` (or malformed attributes) leaves color nil, and a
    /// missing `<offset>` leaves offset nil. A present offset keeps its tag
    /// identity even when either coordinate falls back to zero.
    init(decodingMSCXChildrenOf node: XMLTreeNode) {
        self.init(
            visible: (node.first("visible")?.text ?? "1") != "0",
            color: node.first("color").flatMap(StaffText.decodeColor(_:)),
            offset: node.first("offset").map { offsetNode in
                ScoreOffset(
                    x: offsetNode.attributes["x"].flatMap(Double.init) ?? 0,
                    y: offsetNode.attributes["y"].flatMap(Double.init) ?? 0,
                )
            },
        )
    }

    /// Emits `<offset>` whenever it was present and `<visible>0</visible>`
    /// only when hidden (the default — visible — omits the tag). Neither is a
    /// styled text property, so both can use the ordinary element-property
    /// position without an ordering constraint.
    func mscxChildren() -> [XMLTreeNode] {
        var out: [XMLTreeNode] = []
        if let offset {
            out.append(XMLTreeNode(
                name: "offset",
                attributes: [
                    "x": formatDouble(offset.x),
                    "y": formatDouble(offset.y),
                ],
            ))
        }
        if !visible { out.append(XMLTreeNode(name: "visible", text: "0")) }
        return out
    }

    /// Emits `<color>` at the end of an element's children so a later
    /// `<style>` cannot overwrite the author color while MuseScore reads it.
    ///
    /// This deliberately differs from MuseScore's writer: its
    /// `writeItemProperties` emits `Pid::COLOR` before `Pid::TEXT_STYLE`
    /// (`rw/write/twrite.cpp:1361-1362`), but reading `<style>` calls the
    /// single-argument `TextBase::initTextStyleType` and unconditionally
    /// resets every styled property (`dom/textbase.cpp:3078`), including
    /// color. MuseScore therefore loses an author color on its own round trip.
    /// Writing color last remains valid for the tag-dispatching reader and
    /// preserves that data instead of reproducing the upstream loss.
    func mscxTrailingChildren() -> [XMLTreeNode] {
        guard let color else { return [] }
        return [XMLTreeNode(
            name: "color",
            attributes: [
                "r": String(color.red),
                "g": String(color.green),
                "b": String(color.blue),
                "a": String(color.alpha),
            ],
        )]
    }
}
