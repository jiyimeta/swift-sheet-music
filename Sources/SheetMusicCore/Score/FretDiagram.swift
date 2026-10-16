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
    /// Every `<barre>` of `<fretDiagram>`, in file order.
    public var barres: [FretBarre]
    /// The first barre — read and written as `barres.first`, for callers of the one-barre model. Setting it replaces
    /// or removes the FIRST barre only: any later barre stays, so `barre = nil` on a two-barre diagram leaves one.
    public var barre: FretBarre? {
        get { barres.first }
        set {
            if let newValue {
                if barres.isEmpty { barres = [newValue] } else { barres[0] = newValue }
            } else if !barres.isEmpty {
                barres.removeFirst()
            }
        }
    }

    /// `<fretOffset>`: the fret the diagram starts below, 0 for one starting at the nut. `nil` keeps an absent tag
    /// absent.
    public var fretOffset: Int?
    /// `<showNut>`. `nil` keeps an absent tag absent; MuseScore's default draws the nut.
    public var showNut: Bool?
    /// `<orientation>`. `nil` keeps an absent tag absent; MuseScore's default is vertical.
    public var orientation: Orientation?
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
        barres: [FretBarre] = [],
        fretOffset: Int? = nil,
        showNut: Bool? = nil,
        orientation: Orientation? = nil,
        harmony: Harmony? = nil,
        elementProperties: ElementProperties = .default,
        preservedMarkup: [PreservedXML] = [],
    ) {
        self.stringCount = stringCount
        self.fretCount = fretCount
        self.strings = strings
        self.barres = barres
        self.fretOffset = fretOffset
        self.showNut = showNut
        self.orientation = orientation
        self.harmony = harmony
        self.elementProperties = elementProperties
        self.preservedMarkup = preservedMarkup
    }

    /// MuseScore's `Orientation`: vertical or horizontal. `.other` keeps a number from a file ssm wrote before 4.12,
    /// which stored the enum ordinal; MuseScore reads such a value as vertical, and so does layout.
    public enum Orientation: Sendable, Hashable {
        case vertical
        case horizontal
        case other(Int)

        /// MuseScore's enum ordinal: 0 vertical, 1 horizontal.
        public var mscxOrdinal: Int {
            switch self {
            case .vertical: 0
            case .horizontal: 1
            case let .other(value): value
            }
        }

        public init(mscxOrdinal: Int) {
            switch mscxOrdinal {
            case 0: self = .vertical
            case 1: self = .horizontal
            default: self = .other(mscxOrdinal)
            }
        }

        /// How `<orientation>` spells it: MuseScore's "vertical" / "horizontal" (`TConv::toXml(Orientation)`,
        /// `typesconv.cpp:1072-1089`), and an `.other` as the number it was read from.
        package var mscxText: String {
            switch self {
            case .vertical: "vertical"
            case .horizontal: "horizontal"
            case let .other(value): String(value)
            }
        }

        /// Reverse of `mscxText`. A number is kept as `.other` rather than mapped by ordinal: MuseScore only ever
        /// writes the names, and reads anything else as vertical. Any other text is `nil`.
        package init?(mscxText: String) {
            switch mscxText {
            case "vertical": self = .vertical
            case "horizontal": self = .horizontal
            default:
                guard let value = Int(mscxText) else { return nil }
                self = .other(value)
            }
        }
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
