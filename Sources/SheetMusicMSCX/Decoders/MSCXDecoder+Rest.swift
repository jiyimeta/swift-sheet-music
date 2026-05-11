import Foundation
import SheetMusicCore
import SheetMusicXMLTools

/// Decoder for MSCX `<Rest>` elements. In our model rests are
/// represented as empty `Chord` values, so this returns a `Chord`
/// with `notes: []` and the parsed duration.
enum MSCXRestDecoder {
    static func decode(_ node: XMLTreeNode) throws -> Chord {
        guard let durationText = node.first("durationType")?.text else {
            throw SheetMusicError.malformedScore(
                reason: "Rest missing <durationType>",
            )
        }
        let duration = try duration(
            forDurationType: durationText, node: node,
        )
        return Chord(duration: duration, notes: [])
    }

    private static func duration(
        forDurationType type: String, node: XMLTreeNode,
    ) throws -> NoteDuration {
        if type == "measure" {
            // Full-measure rest: <duration>N/D</duration> gives the actual time.
            let text = node.first("duration")?.text ?? "4/4"
            let frac = Fraction(mscxString: text)
                ?? Fraction(numerator: 4, denominator: 4)
            return .fraction(frac)
        }
        guard let base = NoteDuration(mscxName: type) else {
            throw SheetMusicError.malformedScore(
                reason: "Rest unknown durationType \"\(type)\"",
            )
        }
        let dots = Int(node.first("dots")?.text ?? "0") ?? 0
        return base.dotted(dots)
    }
}
