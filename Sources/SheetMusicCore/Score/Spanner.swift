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
        case vibrato = "Vibrato"
        case trill = "Trill"
        case palmMute = "PalmMute"
        case letRing = "LetRing"
        case other
    }

    /// Which side of the staff an element sits on.
    /// C++: `mu::engraving::PlacementV`; MSCX tokens "above" / "below"
    /// (`typesconv.cpp:2183-2184`).
    public enum Placement: String, Sendable, Equatable {
        case above
        case below
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
    /// Smallest volta ending number, or 0 when `voltaEndings` is
    /// empty. Mirrors `Volta::firstEnding` — the 0 case signals
    /// "no endings recorded" to jump processing
    /// (repeatlist.cpp:813-819).
    public var firstEnding: Int {
        voltaEndings.min() ?? 0
    }

    /// Largest volta ending number, or 0 when `voltaEndings` is
    /// empty. Mirrors `Volta::lastEnding` (repeatlist.cpp:821-828).
    public var lastEnding: Int {
        voltaEndings.max() ?? 0
    }

    /// Base element properties shared with every engravable element.
    /// Currently carries only `<visible>`; see `ElementProperties`.
    public var elementProperties: ElementProperties
    /// MuseScore `<visible>0</visible>` flag. When false the spanner
    /// is hidden — layout omits it entirely (no glyphs, no reserved
    /// space). Playback / MIDI continue to honor the spanner. Sugar over
    /// `elementProperties.visible`.
    public var visible: Bool {
        get { elementProperties.visible }
        set { elementProperties.visible = newValue }
    }

    /// MuseScore `<beginText>` — the label a line spanner prints at
    /// its left end. A `TextLineBase` property, so it can appear on
    /// any line-shaped spanner (`TextLine`, `PalmMute`, `LetRing`, …),
    /// and MuseScore only writes it when it differs from the style
    /// default. `nil` = "use whatever this spanner kind defaults to".
    /// C++: `mu::engraving::TextLineBase::beginText`.
    public var beginText: String?
    /// MuseScore `<placement>` — an author override of the side of the
    /// staff this spanner sits on. `nil` means "use the styled side for
    /// this kind / subtype", which is what MuseScore's absence of the
    /// element means: it writes the tag only once the property stops
    /// being styled (`TWrite::writeItemProperties`, twrite.cpp:578).
    public var placement: Placement?

    public var hairpin: HairpinPayload?
    /// MuseScore `<Ottava><subtype>8va</subtype></Ottava>` payload.
    /// Meaningful only when `kind == .ottava`. Drives MIDI pitch
    /// transposition during playback.
    public var ottava: OttavaPayload?
    /// MuseScore `<Vibrato><subtype>…</subtype></Vibrato>` payload.
    /// Meaningful only when `kind == .vibrato`. Controls which SMuFL
    /// wiggle glyph is repeated along the line during rendering.
    public var vibrato: VibratoPayload?
    /// MuseScore `<Trill><subtype>…</subtype></Trill>` payload.
    /// Meaningful only when `kind == .trill`. Selects the SMuFL glyph
    /// pair repeated along the line during rendering.
    public var trill: TrillPayload?

    public init(
        kind: Kind,
        rawType: String,
        nextMeasuresOffset: Int = 0,
        nextFractionsOffset: Fraction? = nil,
        voltaEndings: [Int] = [],
        visible: Bool = true,
        beginText: String? = nil,
        placement: Placement? = nil,
        hairpin: HairpinPayload? = nil,
        ottava: OttavaPayload? = nil,
        vibrato: VibratoPayload? = nil,
        trill: TrillPayload? = nil,
    ) {
        self.kind = kind
        self.rawType = rawType
        self.nextMeasuresOffset = nextMeasuresOffset
        self.nextFractionsOffset = nextFractionsOffset
        self.voltaEndings = voltaEndings
        elementProperties = ElementProperties(visible: visible)
        self.beginText = beginText
        self.placement = placement
        self.hairpin = hairpin
        self.ottava = ottava
        self.vibrato = vibrato
        self.trill = trill
    }

    /// MuseScore `<Trill>` payload.
    /// C++: `mu::engraving::Trill`.
    public struct TrillPayload: Sendable, Equatable {
        public var type: TrillType

        public init(type: TrillType) {
            self.type = type
        }
    }

    /// MuseScore `<HairPin>` payload needed for MIDI playback.
    /// Meaningful only when `kind == .hairpin`. Nil for other kinds.
    /// C++: `mu::engraving::Hairpin`.
    public struct HairpinPayload: Sendable, Equatable {
        /// C++: `mu::engraving::HairpinType` (`hairpin.h:32`). The two
        /// `*Line` members print MuseScore's "cresc." / "dim." text
        /// with a dashed continuation line instead of a wedge, but
        /// they drive playback exactly like the wedge forms.
        public enum Subtype: Int, Sendable {
            case crescendo = 0
            case decrescendo = 1
            case crescLine = 2
            case dimLine = 3

            /// C++: `Hairpin::isCrescendo` (`hairpin.h:141-144`).
            /// Playback and wedge direction must both branch on this,
            /// never on `== .crescendo`.
            public var isCrescendo: Bool {
                self == .crescendo || self == .crescLine
            }

            /// C++: `Hairpin::isLineType` (`hairpin.h:156-159`).
            /// True for the two text-line forms.
            public var isLineType: Bool {
                self == .crescLine || self == .dimLine
            }
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
        /// normalized to nil at decode time.
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
        /// MuseScore `<numbersOnly>` — a per-element override of
        /// `ScoreStyle.ottavaNumbersOnly`. `nil` = inherit the style.
        /// C++: `Pid::NUMBERS_ONLY`, written unconditionally by
        /// `TWrite::write(const Ottava*)` (twrite.cpp:2445).
        public var numbersOnly: Bool?

        public init(subtype: Subtype, numbersOnly: Bool? = nil) {
            self.subtype = subtype
            self.numbersOnly = numbersOnly
        }
    }

    /// MuseScore `<Vibrato>` payload. The subtype selects which SMuFL
    /// glyph is repeated along the vibrato marking during rendering.
    /// C++: `mu::engraving::Vibrato`.
    public struct VibratoPayload: Sendable, Equatable {
        public var type: VibratoType

        public init(type: VibratoType) {
            self.type = type
        }
    }
}
