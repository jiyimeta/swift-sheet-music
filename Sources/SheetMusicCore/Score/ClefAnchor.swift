import Foundation

/// Identifies a specific clef instance in a `Score` for selection
/// and editing.
///
/// - `.explicit` — a `VoiceElement.clef(Clef)` at a known voice-element
///   location.
/// - `.staffDefault` — the synthesized opening clef rendered when the
///   first measure has no explicit `<Clef>`; sourced from
///   `Staff.defaultClefType`.
public enum ClefAnchor: Hashable, Sendable {
    case explicit(VoiceElementID)
    case staffDefault(StaffAddress)
}
