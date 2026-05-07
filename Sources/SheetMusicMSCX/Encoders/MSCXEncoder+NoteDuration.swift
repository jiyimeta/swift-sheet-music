import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension NoteDuration {
    /// MuseScore `<durationType>` text for the named cases.
    /// Inverse of `init?(mscxName:)`. `.fraction` returns nil — the
    /// caller emits `measure` + `<duration>` instead.
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

    /// Append `<durationType>` (and `<duration>` for fractions)
    /// children to `children`. Used by Chord and Rest encoders.
    func appendDurationXML(to children: inout [XMLTreeNode]) {
        if let name = mscxName {
            children.append(XMLTreeNode(name: "durationType", text: name))
            return
        }
        // fraction: emit `measure` durationType + concrete fraction
        if case let .fraction(f) = self {
            children.append(XMLTreeNode(
                name: "durationType", text: "measure"
            ))
            children.append(XMLTreeNode(
                name: "duration",
                text: "\(f.numerator)/\(f.denominator)"
            ))
        }
    }
}
