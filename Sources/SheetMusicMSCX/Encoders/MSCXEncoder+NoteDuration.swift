import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension NoteDuration {
    /// MuseScore `<durationType>` text for the named cases.
    /// Inverse of `init?(mscxName:)`. `.fraction` returns nil — the
    /// caller emits `measure` + `<duration>` instead, or attempts
    /// `decomposed()` first.
    var mscxName: String? {
        switch self {
        case .whole: "whole"
        case .half: "half"
        case .quarter: "quarter"
        case .eighth: "eighth"
        case .sixteenth: "16th"
        case .thirtySecond: "32nd"
        case .sixtyFourth: "64th"
        case .oneTwentyEighth: "128th"
        case .twoFiftySixth: "256th"
        case .fraction: nil
        }
    }

    /// Try to express this duration as a named base + 0–3 dots.
    /// Returns nil for `.fraction` values that don't match any
    /// such combination (which is rare but possible — e.g., a
    /// 5/64 duration produced by an exotic tuplet ratio).
    func decomposed() -> (name: String, dots: Int)? {
        let target = asFraction
        let bases: [NoteDuration] = [
            .whole, .half, .quarter, .eighth, .sixteenth,
            .thirtySecond, .sixtyFourth, .oneTwentyEighth, .twoFiftySixth,
        ]
        for base in bases {
            // mscxName is non-nil for every element of `bases`.
            guard let name = base.mscxName else { continue }
            for dots in 0 ... 3 where base.dotted(dots).asFraction == target {
                return (name, dots)
            }
        }
        return nil
    }

    /// Append `<durationType>` (and optionally `<dots>` or
    /// `<duration>`) children to `children`.
    ///
    /// Prefers a named base + dots when possible (the form Chord
    /// requires); falls back to `<durationType>measure</durationType>`
    /// + `<duration>N/D</duration>` only for `.fraction` values that
    /// cannot be decomposed (Rest accepts this form; Chord does not).
    ///
    /// Element order matches MuseScore Studio's writer: `<dots>`
    /// precedes `<durationType>`. Emitting them in the reverse
    /// order (durationType first) makes MuseScore's loader read the
    /// duration without dots — the chord renders as a dotted half
    /// but plays back as a plain half, with the missing 1/4 padded
    /// out as an extra rest.
    func appendDurationXML(to children: inout [XMLTreeNode]) {
        if let parts = decomposed() {
            if parts.dots > 0 {
                children.append(XMLTreeNode(name: "dots", text: String(parts.dots)))
            }
            children.append(XMLTreeNode(name: "durationType", text: parts.name))
            return
        }
        if case let .fraction(f) = self {
            children.append(XMLTreeNode(name: "durationType", text: "measure"))
            children.append(XMLTreeNode(
                name: "duration",
                text: "\(f.numerator)/\(f.denominator)",
            ))
        }
    }
}
