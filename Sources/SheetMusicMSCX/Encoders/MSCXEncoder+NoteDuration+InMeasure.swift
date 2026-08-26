import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension NoteDuration {
    /// Append `<durationType>` (and `<duration>` when needed) for a
    /// duration that may be `.measure`. For `.measure`, emits
    /// `<durationType>measure</durationType><duration>N/D</duration>`
    /// where `N/D` is the supplied effective measure duration. For
    /// every other case, delegates to the context-free overload —
    /// callers that have a measure-duration value in hand can route
    /// every duration through this method without branching.
    func appendDurationXML(
        to children: inout [XMLTreeNode],
        in measureDuration: Fraction,
    ) {
        if case .measure = self {
            children.append(XMLTreeNode(
                name: "durationType", text: "measure",
            ))
            children.append(XMLTreeNode(
                name: "duration",
                text: "\(measureDuration.numerator)/\(measureDuration.denominator)",
            ))
            return
        }
        appendDurationXML(to: &children)
    }
}
