import SheetMusicFoundation

/// A staff range indicator attached at the current voice tick.
/// C++: `mu::engraving::Ambitus` (`dom/ambitus.h:39`), a bare
/// `EngravingItem` stored on its own `SegmentType::Ambitus` segment.
///
/// The four pitch and tonal-pitch-class values are author intent. MuseScore's
/// reader assigns them with `applyLogic: false`, deliberately bypassing
/// derivation and normalization, so this model retains them verbatim.
///
/// **Open note-head group.** `noteHeadGroup` keeps the `<head>` text exactly as
/// written. MuseScore 4.6 writes the `NoteHeadGroup` ordinal, while MuseScore 5
/// may write its name. This library does not otherwise model the roughly thirty
/// note-head groups, so their semantic mapping is deferred until noteheads have
/// a shared model rather than introducing a partial enum here.
///
/// **Nested accidental limitation.** Each accidental wrapper contains a full
/// `<Accidental>`, but only its `<subtype>` is modeled. Any other child in that
/// consumed subtree is lost on decode, matching the existing `ChordOrnament`
/// tradeoff. An unsupported subtype degrades to `nil` after a decoder
/// diagnostic.
public struct Ambitus: Sendable, Equatable {
    /// `<topPitch>`, retained without derivation or validation.
    public var topPitch: Int
    /// `<topTpc>`, retained without derivation or validation.
    public var topTpc: Int
    /// `<bottomPitch>`, retained without derivation or validation.
    public var bottomPitch: Int
    /// `<bottomTpc>`, retained without derivation or validation.
    public var bottomTpc: Int
    /// Verbatim `<head>` text: a 4.6 ordinal or a 5.x name token.
    public var noteHeadGroup: String?
    /// `<headType>`, accepting both 4.6 ordinals and 5.x name tokens.
    public var noteHeadType: NoteHeadType?
    /// `<mirror>`, accepting both 4.6 ordinals and 5.x name tokens.
    public var mirror: Mirror?
    /// `<hasLine>`. An absent tag means `true`.
    public var hasLine: Bool
    /// `<lineWidth>` in spatium units. `nil` keeps an absent style-derived
    /// value absent rather than synthesizing MuseScore's default.
    public var lineWidth: Double?
    /// The optional accidental drawn at the top of the range.
    public var topAccidental: Accidental?
    /// The optional accidental drawn at the bottom of the range.
    public var bottomAccidental: Accidental?
    /// Base element properties shared with every engravable element.
    public var elementProperties: ElementProperties
    /// Sugar over `elementProperties.visible`.
    public var visible: Bool {
        get { elementProperties.visible }
        set { elementProperties.visible = newValue }
    }

    /// Source XML children this model does not represent.
    public var preservedMarkup: [PreservedXML]

    public init(
        topPitch: Int,
        topTpc: Int,
        bottomPitch: Int,
        bottomTpc: Int,
        noteHeadGroup: String? = nil,
        noteHeadType: NoteHeadType? = nil,
        mirror: Mirror? = nil,
        hasLine: Bool = true,
        lineWidth: Double? = nil,
        topAccidental: Accidental? = nil,
        bottomAccidental: Accidental? = nil,
        elementProperties: ElementProperties = .default,
        preservedMarkup: [PreservedXML] = [],
    ) {
        self.topPitch = topPitch
        self.topTpc = topTpc
        self.bottomPitch = bottomPitch
        self.bottomTpc = bottomTpc
        self.noteHeadGroup = noteHeadGroup
        self.noteHeadType = noteHeadType
        self.mirror = mirror
        self.hasLine = hasLine
        self.lineWidth = lineWidth
        self.topAccidental = topAccidental
        self.bottomAccidental = bottomAccidental
        self.elementProperties = elementProperties
        self.preservedMarkup = preservedMarkup
    }

    /// MuseScore's note-head duration class. Unknown ordinals are retained for
    /// round-trip fidelity rather than collapsing to the default.
    public enum NoteHeadType: Sendable, Hashable {
        case auto
        case whole
        case half
        case quarter
        case brevis
        case other(rawValue: Int)

        /// The integer ordinal MuseScore 4.6 stores in `<headType>`.
        public var mscxOrdinal: Int {
            switch self {
            case .auto: -1
            case .whole: 0
            case .half: 1
            case .quarter: 2
            case .brevis: 3
            case let .other(rawValue): rawValue
            }
        }

        /// Reverse of `mscxOrdinal`, retaining an unrecognized value.
        public init(mscxOrdinal: Int) {
            switch mscxOrdinal {
            case -1: self = .auto
            case 0: self = .whole
            case 1: self = .half
            case 2: self = .quarter
            case 3: self = .brevis
            default: self = .other(rawValue: mscxOrdinal)
            }
        }

        /// The MuseScore 5.x name spelling used when decoding newer files.
        public init?(mscxName: String) {
            switch mscxName {
            case "auto": self = .auto
            case "whole": self = .whole
            case "half": self = .half
            case "quarter": self = .quarter
            case "breve": self = .brevis
            default: return nil
            }
        }
    }

    /// MuseScore's horizontal note-head direction. Unknown ordinals are
    /// retained for round-trip fidelity rather than collapsing to the default.
    public enum Mirror: Sendable, Hashable {
        case auto
        case left
        case right
        case other(rawValue: Int)

        /// The integer ordinal MuseScore 4.6 stores in `<mirror>`.
        public var mscxOrdinal: Int {
            switch self {
            case .auto: 0
            case .left: 1
            case .right: 2
            case let .other(rawValue): rawValue
            }
        }

        /// Reverse of `mscxOrdinal`, retaining an unrecognized value.
        public init(mscxOrdinal: Int) {
            switch mscxOrdinal {
            case 0: self = .auto
            case 1: self = .left
            case 2: self = .right
            default: self = .other(rawValue: mscxOrdinal)
            }
        }

        /// The MuseScore 5.x name spelling used when decoding newer files.
        public init?(mscxName: String) {
            switch mscxName {
            case "auto": self = .auto
            case "left": self = .left
            case "right": self = .right
            default: return nil
            }
        }
    }
}
