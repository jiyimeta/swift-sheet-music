import Foundation

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
    /// Appended in SP1. The five above are wire indices 0…4 and must keep them.
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
}
