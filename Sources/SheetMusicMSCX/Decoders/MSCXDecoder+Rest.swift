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
            // Full-measure rest: the `<duration>` element gives the
            // actual time. MS3+ writes `<duration>N/D</duration>`
            // (text); MS2 writes `<duration z="N" n="D"/>` (attrs,
            // C++: `Fraction::write` in MuseScore 2 `libmscore/xml.cpp`).
            // Falling back to 4/4 on absence silently collapses
            // irregular-meter measures (e.g. 5/4 → 4/4); accept both
            // forms.
            let frac: Fraction = {
                guard let dur = node.first("duration") else {
                    return Fraction(numerator: 4, denominator: 4)
                }
                if let zText = dur.attributes["z"],
                   let nText = dur.attributes["n"],
                   let z = Int(zText),
                   let n = Int(nText),
                   n > 0
                {
                    return Fraction(numerator: z, denominator: n)
                }
                return Fraction(mscxString: dur.text)
                    ?? Fraction(numerator: 4, denominator: 4)
            }()
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
