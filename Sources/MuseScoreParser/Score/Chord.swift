import Foundation

/// A simultaneously-sounding group of notes with a shared duration.
/// C++: `mu::engraving::Chord` (subset).
public struct Chord: Sendable, Equatable {
    public var duration: NoteDuration
    public var notes: [Note]
    /// Optional arpeggio that spreads the chord's notes in time.
    public var arpeggio: Arpeggio?

    public init(duration: NoteDuration, notes: [Note], arpeggio: Arpeggio? = nil) {
        self.duration = duration
        self.notes = notes
        self.arpeggio = arpeggio
    }
}
