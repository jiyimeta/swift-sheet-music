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
    /// Grace notes that play *before* this chord. Stored in mscx
    /// (left-to-right) order. They don't consume voice time —
    /// `MidiRenderer+Grace` steals from this chord's head or the
    /// previous chord's tail to fit them in.
    public var graceNotesBefore: [GraceChord]
    /// Grace notes that play *after* this chord. Same conventions
    /// as `graceNotesBefore`; their playback time is stolen from
    /// the tail of this chord.
    public var graceNotesAfter: [GraceChord]
    /// Chord-level articulations (staccato / staccatissimo / tenuto and
    /// round-trip-preserved unknowns). C++: `Chord::_articulations`.
    public var articulations: [ChordArticulation]

    public init(
        duration: NoteDuration,
        notes: ChordNotes,
        arpeggio: Arpeggio? = nil,
        lyrics: [Lyric] = [],
        graceNotesBefore: [GraceChord] = [],
        graceNotesAfter: [GraceChord] = [],
        articulations: [ChordArticulation] = [],
    ) {
        self.duration = duration
        self.notes = notes
        self.arpeggio = arpeggio
        self.lyrics = lyrics
        self.graceNotesBefore = graceNotesBefore
        self.graceNotesAfter = graceNotesAfter
        self.articulations = articulations
    }
}
