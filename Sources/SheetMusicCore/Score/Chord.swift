import Foundation

/// A simultaneously-sounding group of notes with a shared duration.
/// C++: `mu::engraving::Chord` (subset).
public struct Chord: Sendable, Equatable {
    public var duration: NoteDuration
    /// Notes belonging to this chord. The pitch-uniqueness
    /// invariant lives in `ChordNotes` itself: assignments,
    /// appends, and in-place mutations all dedupe by `Note.pitch`.
    public var notes: ChordNotes
    /// Optional arpeggio that spreads the chord's notes in time.
    public var arpeggio: Arpeggio?
    /// Lyrics syllable(s) attached to this chord, one per verse line.
    /// Most scores use a single verse (index 0). C++: `mu::engraving::Lyrics`.
    public var lyrics: [Lyric]

    public init(
        duration: NoteDuration,
        notes: ChordNotes,
        arpeggio: Arpeggio? = nil,
        lyrics: [Lyric] = []
    ) {
        self.duration = duration
        self.notes = notes
        self.arpeggio = arpeggio
        self.lyrics = lyrics
    }
}
