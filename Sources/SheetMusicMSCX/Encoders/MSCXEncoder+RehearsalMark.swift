import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension RehearsalMark {
    /// Build a `<RehearsalMark>` element. Mirrors
    /// `RehearsalMark.decode(_:)`: `<text>`, optional `<color>`,
    /// optional `<offset>`, and the `TextProperties` block.
    /// `frame` is folded back into `<frameType>` (decoder strips it
    /// out of `properties` and surfaces it as the dedicated
    /// `frame` field).
    func encode() -> XMLTreeNode {
        var children: [XMLTreeNode] = [
            XMLTreeNode(name: "text", text: text),
        ]
        if let color {
            children.append(XMLTreeNode(
                name: "color",
                attributes: [
                    "r": String(color.red),
                    "g": String(color.green),
                    "b": String(color.blue),
                    "a": String(color.alpha),
                ]
            ))
        }
        if offsetX != 0 || offsetY != 0 {
            children.append(XMLTreeNode(
                name: "offset",
                attributes: [
                    "x": formatDouble(offsetX),
                    "y": formatDouble(offsetY),
                ]
            ))
        }
        var props = properties
        props.frameType = frame
        props.appendXML(to: &children)
        return XMLTreeNode(name: "RehearsalMark", children: children)
    }
}
