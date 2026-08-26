import SheetMusicFoundation

/// What a host asked the score to become — the unit of editing that crosses a process or image boundary.
///
/// An intent is deliberately *scalar*: identities and numbers only, never a slice of the score. That is what lets an
/// Android host relay one to a second copy of this module as a handful of bytes, and lets both copies plan it into
/// the same commands rather than shipping the commands themselves. The heavy commands — the ones carrying whole
/// `VoiceElement` subtrees — are built on each side from these scalars and never travel.
///
/// The case order is part of the wire format (`EditIntentWire`). Append; never renumber.
public enum EditIntent: Sendable, Equatable {
    /// Write a note into a rest slot. `duration` retimes the slot in the same undo step; `nil` keeps the slot's
    /// current length.
    case inputNote(at: RestID, pitch: Int, tpc: Int, duration: NoteDuration?)
    case setRestDuration(at: VoiceElementID, duration: NoteDuration)
    case setChordDuration(at: VoiceElementID, duration: NoteDuration)
    case delete(at: VoiceElementID)
    /// Several intents as one undo step.
    indirect case composite([EditIntent])

    // Appended after the five cases above, which are wire indices 0…4 and must keep them.

    /// Retune one note within a chord. `accidental` is the glyph to display, or `nil` to suppress it.
    case setNotePitch(at: NoteID, pitch: Int, tpc: Int, accidental: Accidental?)
    /// Apply (or clear, when `accidental` is `nil`) an explicit accidental on a note, preserving its diatonic
    /// letter.
    case setAccidental(at: NoteID, accidental: Accidental?)
    /// Append a note to an existing chord.
    case addNoteToChord(at: VoiceElementID, pitch: Int, tpc: Int, accidental: Accidental?)
    /// Drop one note from a chord. Removing the last note collapses the chord to a rest.
    case removeNoteFromChord(at: NoteID)
    /// Tie two adjacent notes, or remove a tie when both `sourceTieForward` and `targetTieBack` are `nil`.
    case setTie(from: NoteID, to: NoteID, sourceTieForward: Int?, targetTieBack: Int?)
    /// Convert the chord or rest at `at` into a tuplet of `actualNotes` members in the time of `normalNotes`.
    case createTuplet(at: VoiceElementID, actualNotes: Int, normalNotes: Int)
    /// Collapse the tuplet containing `at` back into a single chord or rest of the same tick span.
    case removeTuplet(at: VoiceElementID)

    /// Write a note into a slot that already holds a chord: re-pitch it, and re-time it to `duration` in the same
    /// undo step. `nil` keeps the slot's current length.
    ///
    /// Distinct from `.inputNote`, which targets a rest — and deliberately not a widening of it, because a rest slot
    /// and an occupied one differ in what "write a note here" has to do. The separation earns its keep at the
    /// barline: when `duration` outruns the bar this spells the note as a tied chain carrying the NEW pitch, which
    /// `.setChordDuration` followed by `.setNotePitch` cannot express. The chain is planned by cloning a chord, so
    /// the second intent would retune only the chain's head and leave its tail tied to it at the old pitch.
    case writeNote(at: VoiceElementID, pitch: Int, tpc: Int, duration: NoteDuration?)

    /// Make the timed slot at `at` a rest of `duration`, whatever is in it now — the rest key's own meaning, over a
    /// note as much as over a rest.
    ///
    /// Distinct from `.setRestDuration`, which only re-times a rest, and NOT expressible as
    /// `.composite([.delete, .setRestDuration])`: `.delete` collapses a bar it empties into one measure rest, which
    /// would throw away the very length this intent is stating and take the bar's remaining subdivision with it.
    /// The delete here is the plain one, on purpose. `.delete` keeps its collapse — that is right for ⌫, which is
    /// emptying the bar rather than stating a length.
    case writeRest(at: VoiceElementID, duration: NoteDuration)

    /// Insert a blank measure column before `index`; `index == measureCount` appends at the end.
    case insertMeasure(at: Int)
    /// Delete the measure column at `index`.
    case deleteMeasure(at: Int)

    /// Insert a new part built from `plan` before `index`; `index == parts.count` appends. The one intent that
    /// carries something other than scalars — a `PartPlan` is the instrument's identity and staff list, not a slice
    /// of the score, and both images build the same `Part` from it rather than shipping the built part across.
    ///
    /// An out-of-range `index` is refused as `.targetNotFound` by `AddPart.apply` rather than by the session's
    /// planner: one place states the range, and the answer is the same whether the command is reached through an
    /// intent or built directly.
    case addPart(plan: BlankScoreTemplate.PartPlan, at: Int)
}
