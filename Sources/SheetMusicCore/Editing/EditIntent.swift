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
}
