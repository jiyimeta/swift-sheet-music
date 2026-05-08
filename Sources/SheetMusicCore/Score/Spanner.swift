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
    /// MuseScore `<visible>0</visible>` flag. When false the spanner
    /// is hidden — layout omits it entirely (no glyphs, no reserved
    /// space). Playback / MIDI continue to honour the spanner.
    public var visible: Bool
    public var hairpin: HairpinPayload?

    public init(
        kind: Kind,
        rawType: String,
        nextMeasuresOffset: Int = 0,
        nextFractionsOffset: Fraction? = nil,
        voltaEndings: [Int] = [],
        visible: Bool = true,
        hairpin: HairpinPayload? = nil
    ) {
        self.kind = kind
        self.rawType = rawType
        self.nextMeasuresOffset = nextMeasuresOffset
        self.nextFractionsOffset = nextFractionsOffset
        self.voltaEndings = voltaEndings
        self.visible = visible
        self.hairpin = hairpin
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
            veloChangeMethod: VeloChangeMethod = .normal
        ) {
            self.subtype = subtype
            self.veloChange = veloChange
            self.veloChangeMethod = veloChangeMethod
        }
    }
}
