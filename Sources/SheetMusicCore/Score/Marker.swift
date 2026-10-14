import SheetMusicFoundation

/// A navigation marker: Segno, Coda, Fine, To Coda and the rest of MuseScore's palette, or a custom one.
/// C++: `mu::engraving::Marker` — a text element whose type decides its default text and label (`markerTypeTable`,
/// `engraving/dom/marker.cpp:51-62`) and which end of its bar it stands at (`Marker::RIGHT_MARKERS`,
/// `dom/marker.h:87-93`).
public struct Marker: Sendable, Equatable {
    /// This library's marker identity. The raw values are folino's command and palette ids, wire values and
    /// fingerprint input, so they never change; they are NOT MuseScore's `<markerType>` names (`mscxName` spells
    /// those — MuseScore's Coda is `codab` and its To Coda `coda`).
    public enum Kind: String, Sendable {
        case segno
        case varsegno
        case coda
        case varcoda
        case codetta
        case fine
        case toCoda
        case toCodaSym
        /// No MuseScore type: an abbreviation this library once modeled as a marker. Saved as MuseScore's Custom type
        /// with its words, it reads back as `.user`.
        case daCapo
        case dalSegno
        /// MuseScore's `DA_CODA`, "Da Coda".
        case daCoda
        /// MuseScore's `DA_DBLCODA`, "Da Doppia Coda".
        case daDoubleCoda
        /// MuseScore's `USER`, "Custom": a marker of no named type, which prints whatever its text says.
        case user
        /// A marker of no particular type, as this library modeled custom markers before it had `.user`; written and
        /// read back as `.user`.
        case other

        /// The label MuseScore gives a marker of this type when the file names none — the third column of
        /// `markerTypeTable` (`dom/marker.cpp:51-62`). Jumps find their `jumpTo` / `playUntil` / `continueAt` targets
        /// by label, so an unlabeled marker still answers to this one. Empty for the types the table has no row for,
        /// which no jump can target unlabeled.
        public var defaultLabel: String {
            switch self {
            case .segno: "segno"
            case .varsegno: "varsegno"
            case .coda: "codab"
            case .varcoda: "varcoda"
            case .codetta: "codetta"
            case .fine: "fine"
            case .toCoda, .toCodaSym, .daCoda, .daDoubleCoda: "coda"
            case .daCapo, .dalSegno, .user, .other: ""
            }
        }

        /// The text MuseScore gives a marker of this type when it has none, as MuseScore xml text — the second column
        /// of `markerTypeTable`, which `Marker::setMarkerType` fills in on reading (`dom/marker.cpp:86-106`).
        /// `.daCapo` and `.dalSegno` print their abbreviation; `.user` and `.other` have no default.
        public var defaultXMLText: String {
            switch self {
            case .segno: "<sym>segno</sym>"
            case .varsegno: "<sym>segnoSerpent1</sym>"
            case .coda: "<sym>coda</sym>"
            case .varcoda: "<sym>codaSquare</sym>"
            case .codetta: "<sym>coda</sym><sym>coda</sym>"
            case .fine: "Fine"
            case .toCoda: "To Coda"
            case .toCodaSym: "To <sym>coda</sym>"
            case .daCoda: "Da Coda"
            case .daDoubleCoda: "Da Doppia Coda"
            case .daCapo: "D.C."
            case .dalSegno: "D.S."
            case .user, .other: ""
            }
        }

        /// MuseScore's `RIGHT_MARKERS` (`dom/marker.h:87-93`): the types that stand at their bar's END — set in the
        /// REPEAT_RIGHT style, and ordered after the bar's other markers when a repeat list is built
        /// (`repeatlist.cpp:590-618`).
        public var isRightMarker: Bool {
            switch self {
            case .fine, .toCoda, .toCodaSym, .daCoda, .daDoubleCoda: true
            case .segno, .varsegno, .coda, .varcoda, .codetta, .daCapo, .dalSegno, .user, .other: false
            }
        }
    }

    public var kind: Kind
    /// The name jumps target ("coda", "segno"), as `<label>` gives it.
    public var label: String
    /// The plain projection of the marker's `<text>` (`RichText.plainText`). Empty when the marker has none — it then
    /// prints its type's default (`displayedRichText`).
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

    /// Label used for jump-target resolution: the explicit `<label>` when present, else the kind's canonical default.
    /// Mirrors how MuseScore's `Marker::label()` always carries the table default when the user hasn't renamed it.
    public var effectiveLabel: String {
        label.isEmpty ? kind.defaultLabel : label
    }

    /// Whether the marker stands at its bar's end (`Kind.isRightMarker`). Within one measure, bar-start (left)
    /// markers order before bar-end (right) markers in the repeat-list; jumps come last.
    public var isRightMarker: Bool {
        kind.isRightMarker
    }

    /// What the marker prints: its formatted text while the markup is current (`richText`), its plain text, or — when
    /// it has none — its type's default (`Kind.defaultXMLText`), the text MuseScore gives it on reading. A marker made
    /// with `Marker(kind:)` therefore prints like MuseScore's palette marker of that type.
    public var displayedRichText: RichText {
        if let richText { return richText }
        if !text.isEmpty { return RichText(plainText: text) }
        return RichText(xmlText: kind.defaultXMLText)
    }
}
