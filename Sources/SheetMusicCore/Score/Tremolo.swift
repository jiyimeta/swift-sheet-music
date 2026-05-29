import Foundation

/// Beamed-stem tremolo notation. Attached to a `Chord`; for two-note
/// tremolo, the value is held by the *first* chord of the pair and the
/// second chord is named by adjacency in the voice's element list.
///
/// C++: `mu::engraving::TremoloSingleChord` / `TremoloTwoChord`.
public struct Tremolo: Sendable, Hashable {
    /// Number of tremolo bars. Maps to MuseScore subtype tokens:
    /// `r8`/`c8` = 1 (eighth bar), `r16`/`c16` = 2, `r32`/`c32` = 3,
    /// `r64`/`c64` = 4 (64th bar).
    public enum Subtype: UInt8, Sendable, Hashable {
        case r8 = 1
        case r16 = 2
        case r32 = 3
        case r64 = 4
    }

    /// `.single`: bars cross the chord's own stem.
    /// `.between`: bars sit between this chord and the next chord in
    /// the same voice. The pair partner is *not* stored as a back-
    /// reference — it is looked up by walking the voice's element list.
    /// Inserting a chord between the start and original follower
    /// silently re-pairs to the new neighbor, matching MuseScore's
    /// editor convention.
    public enum Span: Sendable, Hashable {
        case single
        case between
    }

    /// Stem-stroke variant. v1 MIDI rendering treats `.z` as
    /// `.traditional`. C++: `TremoloStyle`.
    public enum StrokeStyle: String, Sendable, Hashable {
        case `default`
        case traditional
        case z
    }

    public var subtype: Subtype
    public var span: Span
    public var strokeStyle: StrokeStyle

    public init(
        subtype: Subtype,
        span: Span = .single,
        strokeStyle: StrokeStyle = .default,
    ) {
        self.subtype = subtype
        self.span = span
        self.strokeStyle = strokeStyle
    }
}
