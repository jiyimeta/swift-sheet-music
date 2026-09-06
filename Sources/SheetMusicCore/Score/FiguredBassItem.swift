import SheetMusicFoundation

/// One parsed line of a `FiguredBass` indication.
/// C++: `mu::engraving::FiguredBassItem` (`dom/figuredbass.h:91`).
///
/// The five bracket positions surround the prefix, digit, suffix, and
/// continuation line. Their integer values are attributes `b0...b4` on the
/// required `<brackets>` child. The other values are optional children; a
/// present zero ordinal remains distinguishable from an absent child.
public struct FiguredBassItem: Sendable, Equatable {
    /// Optional accidental or mark before the digit.
    public var prefix: Modifier?
    /// Optional figured-bass digit. MuseScore uses `-1` internally for none.
    public var digit: Int?
    /// Optional accidental or mark after the digit.
    public var suffix: Modifier?
    /// Optional duration-continuation line.
    public var continuationLine: ContinuationLine?
    /// `b0`, before the prefix.
    public var bracket0: Parenthesis
    /// `b1`, between the prefix and digit.
    public var bracket1: Parenthesis
    /// `b2`, between the digit and suffix.
    public var bracket2: Parenthesis
    /// `b3`, between the suffix and continuation line.
    public var bracket3: Parenthesis
    /// `b4`, after the continuation line.
    public var bracket4: Parenthesis
    /// Source XML children this item does not represent.
    public var preservedMarkup: [PreservedXML]

    public init(
        prefix: Modifier? = nil,
        digit: Int? = nil,
        suffix: Modifier? = nil,
        continuationLine: ContinuationLine? = nil,
        bracket0: Parenthesis = .none,
        bracket1: Parenthesis = .none,
        bracket2: Parenthesis = .none,
        bracket3: Parenthesis = .none,
        bracket4: Parenthesis = .none,
        preservedMarkup: [PreservedXML] = [],
    ) {
        self.prefix = prefix
        self.digit = digit
        self.suffix = suffix
        self.continuationLine = continuationLine
        self.bracket0 = bracket0
        self.bracket1 = bracket1
        self.bracket2 = bracket2
        self.bracket3 = bracket3
        self.bracket4 = bracket4
        self.preservedMarkup = preservedMarkup
    }

    /// An accidental or diacritic before or after a figured-bass digit.
    /// Unknown ordinals survive as `.other` for round-trip fidelity.
    public enum Modifier: Sendable, Hashable {
        case none
        case doubleFlat
        case flat
        case natural
        case sharp
        case doubleSharp
        case cross
        case backslash
        case slash
        case other(rawValue: Int)

        /// The integer ordinal MuseScore stores in `<prefix>` and `<suffix>`.
        public var mscxOrdinal: Int {
            switch self {
            case .none: 0
            case .doubleFlat: 1
            case .flat: 2
            case .natural: 3
            case .sharp: 4
            case .doubleSharp: 5
            case .cross: 6
            case .backslash: 7
            case .slash: 8
            case let .other(rawValue): rawValue
            }
        }

        /// Reverse of `mscxOrdinal`, retaining an unrecognized value.
        public init(mscxOrdinal: Int) {
            switch mscxOrdinal {
            case 0: self = .none
            case 1: self = .doubleFlat
            case 2: self = .flat
            case 3: self = .natural
            case 4: self = .sharp
            case 5: self = .doubleSharp
            case 6: self = .cross
            case 7: self = .backslash
            case 8: self = .slash
            default: self = .other(rawValue: mscxOrdinal)
            }
        }

        /// A name spelling accepted in addition to MuseScore 4.6's ordinal.
        public init?(mscxName: String) {
            switch mscxName {
            case "none": self = .none
            case "doubleflat": self = .doubleFlat
            case "flat": self = .flat
            case "natural": self = .natural
            case "sharp": self = .sharp
            case "doublesharp": self = .doubleSharp
            case "cross": self = .cross
            case "backslash": self = .backslash
            case "slash": self = .slash
            default: return nil
            }
        }
    }

    /// A round or square parenthesis at one of the five bracket positions.
    /// Unknown ordinals survive as `.other` for round-trip fidelity.
    public enum Parenthesis: Sendable, Hashable {
        case none
        case roundOpen
        case roundClosed
        case squareOpen
        case squareClosed
        case other(rawValue: Int)

        /// The integer ordinal MuseScore stores in a `b0...b4` attribute.
        public var mscxOrdinal: Int {
            switch self {
            case .none: 0
            case .roundOpen: 1
            case .roundClosed: 2
            case .squareOpen: 3
            case .squareClosed: 4
            case let .other(rawValue): rawValue
            }
        }

        /// Reverse of `mscxOrdinal`, retaining an unrecognized value.
        public init(mscxOrdinal: Int) {
            switch mscxOrdinal {
            case 0: self = .none
            case 1: self = .roundOpen
            case 2: self = .roundClosed
            case 3: self = .squareOpen
            case 4: self = .squareClosed
            default: self = .other(rawValue: mscxOrdinal)
            }
        }

        /// A name spelling accepted in addition to MuseScore 4.6's ordinal.
        public init?(mscxName: String) {
            switch mscxName {
            case "none": self = .none
            case "roundOpen": self = .roundOpen
            case "roundClosed": self = .roundClosed
            case "squaredOpen": self = .squareOpen
            case "squaredClosed": self = .squareClosed
            default: return nil
            }
        }
    }

    /// Whether a continuation line stops here or joins the next figure.
    /// Unknown ordinals survive as `.other` for round-trip fidelity.
    public enum ContinuationLine: Sendable, Hashable {
        case none
        case simple
        case extended
        case other(rawValue: Int)

        /// The integer ordinal MuseScore stores in `<continuationLine>`.
        public var mscxOrdinal: Int {
            switch self {
            case .none: 0
            case .simple: 1
            case .extended: 2
            case let .other(rawValue): rawValue
            }
        }

        /// Reverse of `mscxOrdinal`, retaining an unrecognized value.
        public init(mscxOrdinal: Int) {
            switch mscxOrdinal {
            case 0: self = .none
            case 1: self = .simple
            case 2: self = .extended
            default: self = .other(rawValue: mscxOrdinal)
            }
        }

        /// A name spelling accepted in addition to MuseScore 4.6's ordinal.
        public init?(mscxName: String) {
            switch mscxName {
            case "none": self = .none
            case "simple": self = .simple
            case "extended": self = .extended
            default: return nil
            }
        }
    }
}
