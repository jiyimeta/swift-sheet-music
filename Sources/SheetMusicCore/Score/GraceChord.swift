import SheetMusicFoundation

/// A grace-note chord that rides on a `Chord`'s `graceNotesBefore`
/// or `graceNotesAfter` rather than living in `Voice.elements`.
///
/// Why it isn't a `VoiceElement`: graces don't consume voice time —
/// keeping them off `Voice.elements` means tuplet `startIndex /
/// endIndex` semantics, beam grouping (which iterates voice
/// elements), and the cursor-tick walks all stay untouched.
///
/// `duration` here is *visual* (number of stem flags / beams in
/// engraving) — playback length is decided by `MidiRenderer+Grace`
/// from `graceType` + the parent chord's tick length, not by
/// `duration.ticks(division:)`.
///
/// C++: `mu::engraving::Chord` whose `_noteType` is one of the
/// grace cases of `NoteType`.
public struct GraceChord: Sendable, Equatable {
    public var graceType: GraceType
    public var duration: NoteDuration
    public var notes: ChordNotes
    /// Source XML children from the grace `<Chord>` that the reduced
    /// `GraceChord` model does not represent.
    public var preservedMarkup: [PreservedXML] = []

    public init(
        graceType: GraceType,
        duration: NoteDuration,
        notes: ChordNotes,
        preservedMarkup: [PreservedXML] = [],
    ) {
        self.graceType = graceType
        self.duration = duration
        self.notes = notes
        self.preservedMarkup = preservedMarkup
    }
}
