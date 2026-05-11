import Foundation

/// Dynamic marking (pp, p, mp, mf, f, ff, …). Drives MIDI velocity for following notes.
/// C++: `mu::engraving::Dynamic`.
public struct Dynamic: Sendable, Equatable {
    public var subtype: String // "p", "f", "mf", "fff", etc.
    public var velocity: Int // MIDI velocity 1..127
    /// Per-element font overrides. `nil`-fields inherit from
    /// `TextStyleType.dynamics` (Edwin 10 pt italic by default).
    public var properties: TextProperties

    public init(
        subtype: String,
        velocity: Int,
        properties: TextProperties = TextProperties(),
    ) {
        self.subtype = subtype
        self.velocity = velocity
        self.properties = properties
    }
}
