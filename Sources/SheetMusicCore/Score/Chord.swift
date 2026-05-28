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
    /// Tremolo notation attached to this chord. For two-note tremolo
    /// (`.between`), this value is held by the *start* chord of the
    /// pair; the follower is identified by adjacency in the voice's
    /// element list.
    public var tremolo: Tremolo?
    /// Base element properties shared with every engravable element.
    /// Currently carries only `<visible>`; see `ElementProperties`.
    public var elementProperties: ElementProperties
    /// MuseScore `<visible>0</visible>` flag. Sugar over
    /// `elementProperties.visible`. Playback / MIDI is unaffected.
    /// Also covers rests (a rest is a `Chord` with `notes: []`).
    public var visible: Bool {
        get { elementProperties.visible }
        set { elementProperties.visible = newValue }
    }

    /// Visibility of this chord's stem, independent of note visibility.
    /// MuseScore `<Stem><visible>0</visible></Stem>` inside `<Chord>`.
    /// Default `true`. When false, the stem (and flag) glyphs are
    /// suppressed; the noteheads are NOT affected and continue to be
    /// governed by per-note `Note.visible` / `Chord.visible`. Beam
    /// suppression (`<Beam><visible>`) is a separate concern not yet
    /// parsed.
    public var stemVisible: Bool

    public init(
        duration: NoteDuration,
        notes: ChordNotes,
        arpeggio: Arpeggio? = nil,
        lyrics: [Lyric] = [],
        graceNotesBefore: [GraceChord] = [],
        graceNotesAfter: [GraceChord] = [],
        articulations: [ChordArticulation] = [],
        tremolo: Tremolo? = nil,
        visible: Bool = true,
        stemVisible: Bool = true,
    ) {
        self.duration = duration
        self.notes = notes
        self.arpeggio = arpeggio
        self.lyrics = lyrics
        self.graceNotesBefore = graceNotesBefore
        self.graceNotesAfter = graceNotesAfter
        self.articulations = articulations
        self.tremolo = tremolo
        self.stemVisible = stemVisible
        elementProperties = ElementProperties(visible: visible)
    }
}
