import SheetMusicFoundation

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

        /// Canonical label MuseScore assigns a marker of this kind
        /// when the user hasn't typed one — the third column of
        /// markerTypeTable (marker.cpp:51-62). Jump targets
        /// (`jumpTo` / `playUntil` / `continueAt`) resolve against
        /// labels, so an unlabeled marker must still expose its
        /// canonical one. `.daCapo` / `.dalSegno` / `.other` have no
        /// MuseScore marker-type equivalent → empty (never matched).
        ///
        /// Known caveat: mscx `<markerType>` STRINGS differ from these
        /// labels ("coda" file-string = MuseScore TOCODA, "codab" =
        /// CODA); our `Kind(rawValue:)` maps the raw string
        /// case-for-case, so an unlabeled `<markerType>coda</…>`
        /// (rare — MuseScore Studio always writes `<label>`) defaults
        /// per this table's `.coda` row. Files with explicit labels —
        /// all observed fixtures — are unaffected.
        public var defaultLabel: String {
            switch self {
            case .segno: "segno"
            case .varsegno: "varsegno"
            case .coda: "codab"
            case .varcoda: "varcoda"
            case .codetta: "codetta"
            case .fine: "fine"
            case .toCoda, .toCodaSym: "coda"
            case .daCapo, .dalSegno, .other: ""
            }
        }
    }

    public var kind: Kind
    /// User-facing label ("coda", "segno"), often matching `<label>`.
    public var label: String
    /// Display text as rendered (sometimes includes SMuFL glyphs or
    /// translated strings; kept verbatim for round-trip fidelity).
    public var text: String
    public var preservedTextMarkup: PreservedTextMarkup?
    /// Source XML children this model does not represent.
    public var preservedMarkup: [PreservedXML] = []

    public init(
        kind: Kind,
        label: String = "",
        text: String = "",
        preservedMarkup: [PreservedXML] = [],
        preservedTextMarkup: PreservedTextMarkup? = nil,
    ) {
        self.kind = kind
        self.label = label
        self.text = text
        self.preservedTextMarkup = preservedTextMarkup
        self.preservedMarkup = preservedMarkup
    }

    /// Label used for jump-target resolution: the explicit `<label>`
    /// when present, else the kind's canonical default. Mirrors how
    /// MuseScore's `Marker::label()` always carries the table default
    /// when the user hasn't renamed it.
    public var effectiveLabel: String {
        label.isEmpty ? kind.defaultLabel : label
    }

    /// True for the marker family MuseScore anchors at measure-END
    /// (RIGHT_MARKERS, marker.h:87-93: FINE / TOCODA / TOCODASYM).
    /// Within one measure, bar-start (left) markers order before
    /// bar-end (right) markers in the repeat-list; jumps come last.
    public var isRightMarker: Bool {
        switch kind {
        case .fine, .toCoda, .toCodaSym: true
        case .segno, .varsegno, .coda, .varcoda, .codetta,
             .daCapo, .dalSegno, .other: false
        }
    }
}
