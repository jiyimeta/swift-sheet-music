import Foundation

/// A pitched note inside a `Chord`. C++: `mu::engraving::Note` (subset).
public struct Note: Sendable, Equatable {
    public var pitch: Int      // MIDI 0..127
    public var tpc: Int        // tonal pitch class
    public var accidental: Accidental?

    public init(pitch: Int, tpc: Int, accidental: Accidental? = nil) {
        self.pitch = pitch
        self.tpc = tpc
        self.accidental = accidental
    }
}
