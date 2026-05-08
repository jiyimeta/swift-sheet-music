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

    public init(
        kind: Kind,
        rawType: String,
        nextMeasuresOffset: Int = 0,
        nextFractionsOffset: Fraction? = nil,
        voltaEndings: [Int] = [],
        visible: Bool = true
    ) {
        self.kind = kind
        self.rawType = rawType
        self.nextMeasuresOffset = nextMeasuresOffset
        self.nextFractionsOffset = nextFractionsOffset
        self.voltaEndings = voltaEndings
        self.visible = visible
    }
}
