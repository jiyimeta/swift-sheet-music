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
                ],
            ))
        }
        if offsetX != 0 || offsetY != 0 {
            children.append(XMLTreeNode(
                name: "offset",
                attributes: [
                    "x": formatDouble(offsetX),
                    "y": formatDouble(offsetY),
                ],
            ))
        }
        var props = properties
        // RehearsalMark defaults to a rectangle frame (MuseScore's
        // `Sid::rehearsalMarkFrameType`). MuseScore Studio omits
        // `<frameType>` when the value matches that default; emitting
        // `<frameType>1</frameType>` would also work but produces
        // larger files than the originals.
        if frame != .rectangle {
            props.frameType = frame
        }
        children.append(contentsOf: elementProperties.mscxChildren())
        props.appendXML(to: &children)
        return XMLTreeNode(name: "RehearsalMark", children: children)
    }
}
