import Foundation

/// A pitched note inside a `Chord`. C++: `mu::engraving::Note` (subset).
public struct Note: Sendable, Equatable {
    public var pitch: Int      // MIDI 0..127
    public var tpc: Int        // tonal pitch class
    public var accidental: Accidental?
    /// Tie continuing forward from this note. `nil` means no tie;
    /// `.some(n)` means a tie numbered `n` (MusicXML `<tie number="N">`;
    /// MSCX ties are positional and default to 1).
    public var tieForward: Int?
    /// Tie ending on this note. See `tieForward`.
    public var tieBack: Int?
    /// Glissando starting on this note and sweeping to the next chord's note.
    /// C++: `<Spanner type="Glissando">` attached to a `<Note>`.
    public var glissando: Glissando?

    public init(
        pitch: Int,
        tpc: Int,
        accidental: Accidental? = nil,
        tieForward: Int? = nil,
        tieBack: Int? = nil,
        glissando: Glissando? = nil
    ) {
        self.pitch = pitch
        self.tpc = tpc
        self.accidental = accidental
        self.tieForward = tieForward
        self.tieBack = tieBack
        self.glissando = glissando
    }
}
