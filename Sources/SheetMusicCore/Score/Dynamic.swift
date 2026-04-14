import Foundation

/// Dynamic marking (pp, p, mp, mf, f, ff, …). Drives MIDI velocity for following notes.
/// C++: `mu::engraving::Dynamic`.
public struct Dynamic: Sendable, Equatable {
    public var subtype: String        // "p", "f", "mf", "fff", etc.
    public var velocity: Int          // MIDI velocity 1..127

    public init(subtype: String, velocity: Int) {
        self.subtype = subtype
        self.velocity = velocity
    }
}
