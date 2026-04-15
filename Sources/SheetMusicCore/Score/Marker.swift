import Foundation

/// Measure-left navigation marker: Segno, Coda, Fine, "To Coda".
/// C++: `mu::engraving::Marker`.
public struct Marker: Sendable, Equatable {
    /// Canonical marker identity (`<markerType>` in MuseScore .mscx).
    public enum Kind: String, Sendable {
        case segno
        case varsegno
        case coda
        case varcoda
        case codetta
        case fine
        case toCoda
        case toCodaSym
        case daCapo
        case dalSegno
        case other
    }

    public var kind: Kind
    /// User-facing label ("coda", "segno"), often matching `<label>`.
    public var label: String
    /// Display text as rendered (sometimes includes SMuFL glyphs or
    /// translated strings; kept verbatim for round-trip fidelity).
    public var text: String

    public init(kind: Kind, label: String = "", text: String = "") {
        self.kind = kind
        self.label = label
        self.text = text
    }
}
