import SheetMusicFoundation

/// A capo instruction attached to a segment at the current voice tick.
/// C++: `mu::engraving::Capo` (`dom/capo.h:28`), a `StaffTextBase` stored as
/// a staff-bound segment annotation. Its MSCX writer and reader begin at
/// `rw/write/twrite.cpp:1298` and `rw/read460/tread.cpp:2720`.
/// The element is MuseScore 4.1 and later. MuseScore v4.6.5's property table,
/// reader, and writer have no `<transposeMode>`; commit `2ad8dd61a8` added it,
/// and v4.7.0 was its first release.
///
/// **The file defaults come from `Capo::propertyDefault`, not the field
/// initializers in `CapoParams`.** An absent `<active>` means `true`, not
/// `false`, and an absent `<fretPosition>` means `1`, not `0`. Likewise,
/// `<generateText>` defaults to `true`. `transposeMode == nil` means its 4.7+
/// tag was absent: a 4.6 file has no such property, while a 4.7+ writer may
/// omit it because `.playbackOnly` equals the property default.
///
/// **Content, not presentation.** The capo parameters and `text` are modeled;
/// `<style>`, font overrides, and the `StaffTextBase` channel and swing tags
/// stay in `preservedMarkup`; the shared base owns `<offset>` and `<placement>`.
/// Inline markup inside `<text>` flattens to plain text, the cross-cutting
/// limitation described by the parity document's §7.1 text-content work.
public struct Capo: Sendable, Equatable {
    /// `<active>`. Defaults to `true` when absent.
    public var isActive: Bool
    /// `<fretPosition>`. Defaults to fret 1 when absent.
    public var fretPosition: Int
    /// `<generateText>`. Whether MuseScore derives the displayed text.
    public var generatesText: Bool
    /// MuseScore 4.7+ `<transposeMode>`, stored as an integer ordinal. `nil`
    /// keeps an absent tag absent rather than synthesizing a 4.7 property.
    public var transposeMode: TransposeMode?
    /// Strings to which the capo does not apply.
    public var ignoredStrings: Set<Int>
    /// The `<text>` payload, flattened to plain text.
    public var text: String
    /// Base element properties shared with every engravable element.
    public var elementProperties: ElementProperties
    /// Sugar over `elementProperties.visible`.
    public var visible: Bool {
        get { elementProperties.visible }
        set { elementProperties.visible = newValue }
    }

    /// Source XML children this model does not represent, including text
    /// presentation, channel, and swing properties.
    public var preservedMarkup: [PreservedXML]

    public init(
        isActive: Bool = true,
        fretPosition: Int = 1,
        generatesText: Bool = true,
        transposeMode: TransposeMode? = nil,
        ignoredStrings: Set<Int> = [],
        text: String,
        elementProperties: ElementProperties = .default,
        preservedMarkup: [PreservedXML] = [],
    ) {
        self.isActive = isActive
        self.fretPosition = fretPosition
        self.generatesText = generatesText
        self.transposeMode = transposeMode
        self.ignoredStrings = ignoredStrings
        self.text = text
        self.elementProperties = elementProperties
        self.preservedMarkup = preservedMarkup
    }

    /// Where a capo transposes notes in MuseScore 4.7 and later. C++:
    /// `CapoParams::TransposeMode` (`types/types.h:1369`). Unknown ordinals are
    /// retained for round-trip fidelity rather than collapsing to MuseScore's
    /// default.
    public enum TransposeMode: Sendable, Hashable {
        case playbackOnly
        case standardOnly
        case tabOnly
        case other(rawValue: Int)

        /// The integer ordinal MuseScore stores in `<transposeMode>`.
        public var mscxOrdinal: Int {
            switch self {
            case .playbackOnly: 0
            case .standardOnly: 1
            case .tabOnly: 2
            case let .other(rawValue): rawValue
            }
        }

        /// Reverse of `mscxOrdinal`, retaining an unrecognized value as
        /// `.other` so it survives a decode/encode round trip.
        public init(mscxOrdinal: Int) {
            switch mscxOrdinal {
            case 0: self = .playbackOnly
            case 1: self = .standardOnly
            case 2: self = .tabOnly
            default: self = .other(rawValue: mscxOrdinal)
            }
        }
    }
}
