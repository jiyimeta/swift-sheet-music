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
    /// Slurs that BEGIN on this grace chord — the same begin sides `Chord.spanners` holds for an ordinary chord,
    /// with the same meaning: the end side is not stored, and `nextMeasuresOffset` / `nextFractionsOffset` /
    /// `nextGraceIndex` locate it the way MuseScore's relative `<location>` does. A grace shares its parent's tick
    /// (`EngravingItem::tick()` resolves through the parent's `Segment`), so the offsets are measured from the parent
    /// chord's position: the common acciaccatura slurred into its own principal note has both offsets at zero and no
    /// `nextGraceIndex`.
    ///
    /// MuseScore writes these inside the grace's own `<Chord>` (`TWrite::writeProperties(const ChordRest*, …)`
    /// makes no exception for graces). Not touched by any structural edit: a slur into the grace's own principal
    /// note, the overwhelming case, needs none, and one reaching another measure keeps its offsets as written.
    public var spanners: [Spanner] = []

    public init(
        graceType: GraceType,
        duration: NoteDuration,
        notes: ChordNotes,
        preservedMarkup: [PreservedXML] = [],
        spanners: [Spanner] = [],
    ) {
        self.graceType = graceType
        self.duration = duration
        self.notes = notes
        self.preservedMarkup = preservedMarkup
        self.spanners = spanners
    }
}
