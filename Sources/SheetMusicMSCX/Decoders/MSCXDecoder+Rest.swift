import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Rest {
    static func decode(_ node: XMLTreeNode) throws -> Rest {
        guard let durationText = node.first("durationType")?.text else {
            throw SheetMusicError.malformedScore(reason: "Rest missing <durationType>")
        }
        let duration = try Self.duration(forDurationType: durationText, node: node)
        return Rest(duration: duration)
    }

    private static func duration(forDurationType type: String, node: XMLTreeNode) throws -> NoteDuration {
        if type == "measure" {
            // Full-measure rest: <duration>N/D</duration> gives the actual time
            let text = node.first("duration")?.text ?? "4/4"
            let frac = Fraction(mscxString: text) ?? Fraction(numerator: 4, denominator: 4)
            return .fraction(frac)
        }
        guard let base = NoteDuration(mscxName: type) else {
            throw SheetMusicError.malformedScore(reason: "Rest unknown durationType \"\(type)\"")
        }
        let dots = Int(node.first("dots")?.text ?? "0") ?? 0
        return base.dotted(dots)
    }
}
