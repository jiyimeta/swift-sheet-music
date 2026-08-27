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

    /// Remove the whole part at `index` — its instrument, its staves and their bars.
    ///
    /// Refused with `.cannotRemoveLastPart` when it would empty the score of parts, and with `.targetNotFound` for
    /// an index that names no part; both answers come from `RemovePart.apply`, so they are the same whether the
    /// command is reached through this intent or built directly.
    case removePart(at: Int)

    /// Move the part at `from` to `to` — a removal followed by an insertion, so `[A, B, C]` with
    /// `.movePart(from: 0, to: 1)` becomes `[B, A, C]`.
    ///
    /// Both indices name positions in the current parts array; unlike `.addPart`, `to == parts.count` is out of
    /// range, because a move cannot grow the score. `from == to` resolves to nothing to apply rather than pushing
    /// an undo entry that restores the score to itself.
    case movePart(from: Int, to: Int)

    /// Set the concert key in force from `measureIndex` to the next explicit key change (or the end of the
    /// score): writes/replaces the `.keySignature` on every non-percussion staff at that measure and
    /// re-spells accidental glyphs over the affected span, as one undo step.
    ///
    /// Resolves to nothing to apply when that key is already the one in force there — restating a key the score
    /// already declares would push an undo entry that restores the score to itself, the same rule `.movePart`
    /// applies to a move onto its own index. An out-of-range `measureIndex` is refused as `.targetNotFound` by
    /// `SetKeySignature.apply`, so one place states the range.
    case setKeySignature(measureIndex: Int, concertKey: Int)

    /// Remove the explicit key change at `measureIndex`, reverting its span to the previous key. Refused
    /// with `.cannotRemoveInitialSignature` at measure 0; plans to nothing when no explicit key change exists
    /// there.
    ///
    /// The span that reverts is re-spelled in the same undo step, for the same reason `.setKeySignature` re-spells
    /// its own: the bars after a removed change are byte-identical and yet every accidental in them is now judged
    /// against a different signature.
    case removeKeySignature(measureIndex: Int)

    /// Set the time signature in force from `measureIndex` to the next explicit time change (or the end of the
    /// score), RE-BARRING that region: its content is re-partitioned into bars of the new length, notes the new
    /// barlines cut are split and tied, and the score's measure count may change. One undo step.
    ///
    /// Resolves to nothing to apply when that meter is already the one in force there — the same rule
    /// `.setKeySignature` and `.movePart` apply to an edit that would restore the score to itself. Refused as a
    /// whole, with the score untouched, when the new barring would split a tuplet
    /// (`.rebarWouldSplitTuplet`) or slide a repeat sign off the barline it marks
    /// (`.rebarWouldDisplaceBarlineMarker`): a re-bar is one edit, so it either lands or it does not.
    case setTimeSignature(measureIndex: Int, numerator: Int, denominator: Int)

    /// Remove the explicit time change at `measureIndex`, re-barring its span back to the meter that was in force
    /// before it. Refused with `.cannotRemoveInitialSignature` at measure 0; plans to nothing when no explicit
    /// time change exists there.
    case removeTimeSignature(measureIndex: Int)
}
