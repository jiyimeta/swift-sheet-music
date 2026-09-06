import SheetMusicFoundation

/// A chord diagram attached to a voice position.
/// C++: `mu::engraving::FretDiagram` (`dom/fretdiagram.h`).
public struct FretDiagram: Sendable, Equatable {
    /// Number of strings in the diagram. MuseScore defaults to six.
    public var stringCount: Int
    /// Number of displayed frets. MuseScore defaults to five.
    public var fretCount: Int
    /// Only strings carrying a marker or at least one dot.
    public var strings: [FretString]
    public var barre: FretBarre?
    /// The chord symbol nested inside `<FretDiagram>`, when present.
    public var harmony: Harmony?
    /// Base element properties shared with every engravable element.
    public var elementProperties: ElementProperties
    /// Sugar over `elementProperties.visible`.
    public var visible: Bool {
        get { elementProperties.visible }
        set { elementProperties.visible = newValue }
    }

    /// Source XML children this model does not represent, including the old
    /// compatibility block MuseScore writes after `<fretDiagram>`.
    public var preservedMarkup: [PreservedXML]

    public init(
        stringCount: Int = 6,
        fretCount: Int = 5,
        strings: [FretString] = [],
        barre: FretBarre? = nil,
        harmony: Harmony? = nil,
        elementProperties: ElementProperties = .default,
        preservedMarkup: [PreservedXML] = [],
    ) {
        self.stringCount = stringCount
        self.fretCount = fretCount
        self.strings = strings
        self.barre = barre
        self.harmony = harmony
        self.elementProperties = elementProperties
        self.preservedMarkup = preservedMarkup
    }
}

/// One string carrying content in a chord diagram.
public struct FretString: Sendable, Equatable {
    /// The zero-based MSCX `no` attribute.
    public var index: Int
    public var marker: Marker?
    public var dots: [Dot]

    public init(
        index: Int = 0,
        marker: Marker? = nil,
        dots: [Dot] = [],
    ) {
        self.index = index
        self.marker = marker
        self.dots = dots
    }

    /// MuseScore's marker tokens. MuseScore maps an unrecognized token to
    /// `none`; this model keeps it verbatim so it survives a round trip.
    public enum Marker: Sendable, Hashable {
        case circle
        case cross
        case none
        case other(String)

        public var mscxToken: String {
            switch self {
            case .circle: "circle"
            case .cross: "cross"
            case .none: "none"
            case let .other(token): token
            }
        }

        public init(mscxToken: String) {
            switch mscxToken {
            case "circle": self = .circle
            case "cross": self = .cross
            case "none": self = .none
            default: self = .other(mscxToken)
            }
        }
    }

    public struct Dot: Sendable, Equatable {
        public var fret: Int
        public var kind: Kind

        public init(fret: Int = 0, kind: Kind = .normal) {
            self.fret = fret
            self.kind = kind
        }

        /// MuseScore's dot tokens. MuseScore maps an unrecognized token to
        /// `normal`; this model keeps it verbatim so it survives a round trip.
        public enum Kind: Sendable, Hashable {
            case normal
            case cross
            case square
            case triangle
            case other(String)

            public var mscxToken: String {
                switch self {
                case .normal: "normal"
                case .cross: "cross"
                case .square: "square"
                case .triangle: "triangle"
                case let .other(token): token
                }
            }

            public init(mscxToken: String) {
                switch mscxToken {
                case "normal": self = .normal
                case "cross": self = .cross
                case "square": self = .square
                case "triangle": self = .triangle
                default: self = .other(mscxToken)
                }
            }
        }
    }
}

/// A barre spanning strings at one fret. An `endString` of -1 means the barre
/// continues to the end of the diagram.
public struct FretBarre: Sendable, Equatable {
    public var startString: Int
    public var endString: Int
    public var fret: Int

    public init(
        startString: Int = 0,
        endString: Int = -1,
        fret: Int = 0,
    ) {
        self.startString = startString
        self.endString = endString
        self.fret = fret
    }
}
