import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension MeasureRepeat {
    /// Build a `<MeasureRepeat>` element. Mirrors
    /// `MeasureRepeat.decode(_:)` — emits `<subtype>` (numMeasures)
    /// then the duration in MuseScore's canonical measure-repeat
    /// form: `<durationType>measure</durationType>` plus a `<duration>
    /// N/D</duration>` fraction. Named-duration constructions
    /// (`.whole`, `.half`, …) round-trip via the standard
    /// `appendDurationXML` path.
    func encode() -> XMLTreeNode {
        var children: [XMLTreeNode] = [
            XMLTreeNode(name: "subtype", text: String(numMeasures)),
        ]
        if case let .fraction(f) = duration {
            children.append(XMLTreeNode(name: "durationType", text: "measure"))
            children.append(XMLTreeNode(
                name: "duration",
                text: "\(f.numerator)/\(f.denominator)"
            ))
        } else {
            duration.appendDurationXML(to: &children)
        }
        return XMLTreeNode(name: "MeasureRepeat", children: children)
    }
}
