import Foundation

/// Generic spanner anchored at one tick and ending at a future tick (next measures away).
/// Subtypes mscx encodes here: Volta, Slur, HairPin, Pedal, etc.
/// For midi rendering we need at least Volta to drive repeat-list expansion.
/// C++: `mu::engraving::Spanner`.
public struct Spanner: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case volta = "Volta"
        case slur = "Slur"
        case hairpin = "HairPin"
        case pedal = "Pedal"
        case ottava = "Ottava"
        case textLine = "TextLine"
        case glissando = "Glissando"
        case other
    }

    public var kind: Kind
    public var rawType: String // original "type" attribute
    public var nextMeasuresOffset: Int // distance to the spanner end in measures
    /// MuseScore `<next><location><fractions>N/D</fractions></location></next>`
    /// inside a `<Spanner>`. Optional because most cross-measure
    /// spanners only emit `<measures>` (whole-measure offsets); the
    /// non-nil case is spanners that end mid-measure.
    public var nextFractionsOffset: Fraction?
    public var voltaEndings: [Int] // for Volta: the take-numbers (1, 2, …)
    /// Base element properties shared with every engravable element.
    /// Currently carries only `<visible>`; see `ElementProperties`.
    public var elementProperties: ElementProperties
    /// MuseScore `<visible>0</visible>` flag. When false the spanner
    /// is hidden — layout omits it entirely (no glyphs, no reserved
    /// space). Playback / MIDI continue to honour the spanner. Sugar over
    /// `elementProperties.visible`.
    public var visible: Bool {
        get { elementProperties.visible }
        set { elementProperties.visible = newValue }
    }

    public var hairpin: HairpinPayload?
    /// MuseScore `<Ottava><subtype>8va</subtype></Ottava>` payload.
    /// Meaningful only when `kind == .ottava`. Drives MIDI pitch
    /// transposition during playback.
    public var ottava: OttavaPayload?

    public init(
        kind: Kind,
        rawType: String,
        nextMeasuresOffset: Int = 0,
        nextFractionsOffset: Fraction? = nil,
        voltaEndings: [Int] = [],
        visible: Bool = true,
        hairpin: HairpinPayload? = nil,
        ottava: OttavaPayload? = nil,
    ) {
        self.kind = kind
        self.rawType = rawType
        self.nextMeasuresOffset = nextMeasuresOffset
        self.nextFractionsOffset = nextFractionsOffset
        self.voltaEndings = voltaEndings
        elementProperties = ElementProperties(visible: visible)
        self.hairpin = hairpin
        self.ottava = ottava
    }

    /// MuseScore `<HairPin>` payload needed for MIDI playback.
    /// Meaningful only when `kind == .hairpin`. Nil for other kinds.
    /// C++: `mu::engraving::Hairpin`.
    public struct HairpinPayload: Sendable, Equatable {
        public enum Subtype: Int, Sendable {
            case crescendo = 0
            case decrescendo = 1
        }

        /// Linear / ease curve. v1 implements `.normal` (linear) only;
        /// other cases fall through to linear in `HairpinRamps.interpolate`.
        public enum VeloChangeMethod: String, Sendable {
            case normal
            case easeIn = "ease-in"
            case easeOut = "ease-out"
            case easeInOut = "ease-in-out"
            case exponential
        }

        public var subtype: Subtype
        /// `<veloChange>` value (1..127). Used when bracket Dynamics
        /// don't pin both endpoints. MuseScore's default of 0 is
        /// normalised to nil at decode time.
        public var veloChange: Int?
        public var veloChangeMethod: VeloChangeMethod

        public init(
            subtype: Subtype,
            veloChange: Int? = nil,
            veloChangeMethod: VeloChangeMethod = .normal,
        ) {
            self.subtype = subtype
            self.veloChange = veloChange
            self.veloChangeMethod = veloChangeMethod
        }
    }

    /// MuseScore `<Ottava>` payload. The subtype string drives the
    /// pitch shift applied during MIDI playback.
    /// C++: `mu::engraving::Ottava`.
    public struct OttavaPayload: Sendable, Equatable {
        /// One of MuseScore's documented ottava subtypes. Unknown
        /// subtypes round-trip via `.other(rawValue)` and fall back
        /// to the `8va` shift (+12) for playback.
        public enum Subtype: Sendable, Equatable {
            case eightVA // 8va — up one octave
            case eightVB // 8vb — down one octave
            case fifteenMA // 15ma — up two octaves
            case fifteenMB // 15mb — down two octaves
            case twentyTwoMA // 22ma — up three octaves
            case twentyTwoMB // 22mb — down three octaves
            case other(String)

            public init(rawValue: String) {
                switch rawValue {
                case "8va": self = .eightVA
                case "8vb": self = .eightVB
                case "15ma": self = .fifteenMA
                case "15mb": self = .fifteenMB
                case "22ma": self = .twentyTwoMA
                case "22mb": self = .twentyTwoMB
                default: self = .other(rawValue)
                }
            }

            /// Pitch shift in semitones for MIDI playback. Unknown
            /// subtypes fall back to `8va` (+12).
            public var semitones: Int {
                switch self {
                case .eightVA: 12
                case .eightVB: -12
                case .fifteenMA: 24
                case .fifteenMB: -24
                case .twentyTwoMA: 36
                case .twentyTwoMB: -36
                case .other: 12
                }
            }

            public var rawValue: String {
                switch self {
                case .eightVA: return "8va"
                case .eightVB: return "8vb"
                case .fifteenMA: return "15ma"
                case .fifteenMB: return "15mb"
                case .twentyTwoMA: return "22ma"
                case .twentyTwoMB: return "22mb"
                case let .other(s): return s
                }
            }
        }

        public var subtype: Subtype

        public init(subtype: Subtype) {
            self.subtype = subtype
        }
    }
}
