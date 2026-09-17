import SheetMusicFoundation

/// Identifies a specific clef instance in a `Score` for selection
/// and editing.
///
/// - `.explicit` — a `VoiceElement.clef(Clef)` at a known voice-element
///   location.
/// - `.staffDefault` — the synthesized opening clef rendered when the
///   first measure has no explicit `<Clef>`; sourced from
///   `Staff.defaultClefType`.
/// - `.restatement` — the synthesized clef a continuation system opens
///   with, named by the bar it is drawn at the head of.
///
/// Cases are appended, never reordered: the declaration order is `ClefAnchorWire`'s choice numbering.
public enum ClefAnchor: Hashable, Sendable {
    case explicit(VoiceElementID)
    case staffDefault(StaffAddress)
    /// The clef a continuation system redraws at its head on `staff`, where bar `measureIndex` opens the system
    /// without declaring a clef of its own.
    ///
    /// **It names the place it is drawn, not the declaration it redraws** — MuseScore's rule for a system-head
    /// clef (`EditClef::undoChangeClef`'s `moveClef`). A change made through it starts a new clef at the head of
    /// `measureIndex` — `SetClef(before:)` on voice 0's first chord or rest of that bar — so earlier systems keep
    /// theirs, and each system's restatement is a selection of its own rather than one tint shared by all of them.
    /// The clef it shows is the one in force at the head of that bar: `Score.clefInForce(at:)` at element 0.
    case restatement(staff: StaffAddress, measureIndex: Int)
}
