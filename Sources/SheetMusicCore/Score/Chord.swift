import Foundation

/// A simultaneously-sounding group of notes with a shared duration.
/// C++: `mu::engraving::Chord` (subset).
public struct Chord: Sendable, Equatable {
    public var duration: NoteDuration
    public var notes: [Note]
    /// Optional arpeggio that spreads the chord's notes in time.
    public var arpeggio: Arpeggio?
    /// Lyrics syllable(s) attached to this chord, one per verse line.
    /// Most scores use a single verse (index 0). C++: `mu::engraving::Lyrics`.
    public var lyrics: [Lyric]

    public init(
        duration: NoteDuration,
        notes: [Note],
        arpeggio: Arpeggio? = nil,
        lyrics: [Lyric] = []
    ) {
        self.duration = duration
        self.notes = notes
        self.arpeggio = arpeggio
        self.lyrics = lyrics
    }
}
