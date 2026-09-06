import SheetMusicFoundation

/// A finger number, guitar-hand fingering, or string number attached to a note.
/// C++: `mu::engraving::Fingering` (`dom/fingering.h`), a `TextBase` that lives
/// in the note's `el()` list.
///
/// A note may carry several — a left-hand fingering and a string number on the
/// same note is ordinary guitar notation — which is why `Note.fingerings` is an
/// array and why `role` is part of the value rather than the collection's key.
///
/// **Content, not presentation.** `text` and `role` are what a reader of the
/// score needs; per-element font overrides stay in `preservedMarkup`, while
/// the shared base owns `<offset>` and `<placement>` through
/// `elementProperties`. Inline markup inside `<text>` — MuseScore
/// writes things like `<text><font size="8"/>2</text>` — flattens to its plain
/// text, the cross-cutting limitation `StaffText` already has.
public struct Fingering: Sendable, Equatable {
    /// The `<text>` payload, flattened to plain text.
    public var text: String
    /// Which of the four fingering-family text styles this is. MuseScore
    /// persists it as `<style>`, and omits the tag for a plain fingering.
    public var role: Role
    /// Base element properties shared with every engravable element, including
    /// the spatium-unit `<offset>`.
    public var elementProperties: ElementProperties
    /// Source XML children this model does not represent, including font
    /// overrides.
    public var preservedMarkup: [PreservedXML]

    public init(
        text: String,
        role: Role = .fingering,
        elementProperties: ElementProperties = .default,
        preservedMarkup: [PreservedXML] = [],
    ) {
        self.text = text
        self.role = role
        self.elementProperties = elementProperties
        self.preservedMarkup = preservedMarkup
    }

    /// The fingering-family members of MuseScore's `TextStyleType`
    /// (`types/typesconv.cpp:1778-1784`). They are text *styles* upstream, but
    /// on a `Fingering` the style is what says whether "2" means a finger, a
    /// hand, or a string — so it is modeled here as the element's role rather
    /// than folded into this library's `TextStyleType`, whose rows carry font
    /// and placement defaults this work does not settle (parity doc §7.3).
    public enum Role: Sendable, Hashable {
        /// `<style>` absent, or `fingering`. MuseScore's default for the
        /// element, so its writer omits the tag.
        case fingering
        /// `guitar_fingering_lh` — left-hand fingering.
        case leftHandGuitar
        /// `guitar_fingering_rh` — right-hand (p/i/m/a) fingering.
        case rightHandGuitar
        /// `string_number` — a circled string number.
        case stringNumber
        /// Any other `<style>` token, kept verbatim so an unusual or
        /// user-defined style survives a round trip.
        case other(style: String)

        /// The `<style>` token, or `nil` for the role MuseScore writes no tag
        /// for.
        public var mscxToken: String? {
            switch self {
            case .fingering: nil
            case .leftHandGuitar: "guitar_fingering_lh"
            case .rightHandGuitar: "guitar_fingering_rh"
            case .stringNumber: "string_number"
            case let .other(style): style
            }
        }

        /// Reverse of `mscxToken`. An unrecognized token becomes `.other`
        /// rather than `nil`: unlike a subtype, a text style outside the
        /// fingering family is still meaningful markup to hand back.
        public init(mscxToken: String) {
            switch mscxToken {
            case "fingering": self = .fingering
            case "guitar_fingering_lh": self = .leftHandGuitar
            case "guitar_fingering_rh": self = .rightHandGuitar
            case "string_number": self = .stringNumber
            default: self = .other(style: mscxToken)
            }
        }
    }
}
