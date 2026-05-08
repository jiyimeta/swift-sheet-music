import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension MeasureRepeat {
    /// Build a `<MeasureRepeat>` element. Mirrors
    /// `MeasureRepeat.decode(_:)` — emits `<subtype>` (numMeasures)
    /// and the standard `<durationType>` (+ optional `<duration>`)
    /// pair via `NoteDuration.appendDurationXML`.
    func encode() -> XMLTreeNode {
        var children: [XMLTreeNode] = [
            XMLTreeNode(name: "subtype", text: String(numMeasures)),
        ]
        duration.appendDurationXML(to: &children)
        return XMLTreeNode(name: "MeasureRepeat", children: children)
    }
}
