import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension MeasureRepeat {
    static func decode(_ node: XMLTreeNode) throws -> MeasureRepeat {
        let num = Int(node.first("subtype")?.text ?? "1") ?? 1
        let durationText = node.first("durationType")?.text ?? "measure"
        let duration: NoteDuration
        if durationText == "measure" {
            // `<duration>` is informational; the encoder re-derives
            // it from the measure's effective duration.
            duration = .measure
        } else {
            duration = NoteDuration(mscxName: durationText)
                ?? .measure
        }
        return MeasureRepeat(numMeasures: num, duration: duration)
    }
}
