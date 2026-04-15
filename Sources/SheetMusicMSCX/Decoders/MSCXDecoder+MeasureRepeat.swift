import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension MeasureRepeat {
    static func decode(_ node: XMLTreeNode) throws -> MeasureRepeat {
        let num = Int(node.first("subtype")?.text ?? "1") ?? 1
        let durationText = node.first("durationType")?.text ?? "measure"
        let duration: NoteDuration
        if durationText == "measure" {
            let fracText = node.first("duration")?.text ?? "4/4"
            let frac = Fraction(mscxString: fracText) ?? Fraction(numerator: 4, denominator: 4)
            duration = .fraction(frac)
        } else {
            duration = NoteDuration(mscxName: durationText) ?? .fraction(Fraction(numerator: 4, denominator: 4))
        }
        return MeasureRepeat(numMeasures: num, duration: duration)
    }
}
