import Foundation

/// Replaces the chord or rest at `location` with a rest of the same
/// duration, preserving the measure's tick total. Used for the
/// "delete selection" UX on a chord (deletes the whole chord
/// including every note in it). Single-note removal from a chord
/// would be a separate command.
///
/// Behaviour by element kind:
///   - `.chord` with notes: replaced with `.rest(duration:)` of the
///     same duration (an empty `Chord`).
///   - `.chord` already empty (= rest): replaced with itself
///     (idempotent — still recorded in the undo stack so a
///     subsequent edit's undo path stays consistent).
///   - any other element kind throws `SheetMusicError.invalidEdit`.
///
/// Inverse is a `ReplaceVoiceElement` that restores the original
/// element verbatim, so undo brings back the chord with all its
/// notes / accidentals / ties.
///
/// > Note: This command is sugar over `ReplaceVoiceElement` with a
/// > same-duration empty chord. It exists to give the operation a
/// > domain-meaningful name and to centralise the duration lookup;
/// > callers can equally construct the equivalent
/// > `ReplaceVoiceElement` directly. See `docs/edit-commands.md`
/// > for the policy.
public struct DeleteVoiceElement: EditCommand {
    public let location: VoiceElementID

    public init(at location: VoiceElementID) {
        self.location = location
    }

    public var affectedLocation: VoiceElementID { location }

    @discardableResult
    public func apply(to score: inout Score) throws -> any EditCommand {
        guard let original = score[location] else {
            throw SheetMusicError.invalidEdit(
                reason: "DeleteVoiceElement: no element at \(location)")
        }
        let duration: NoteDuration
        switch original {
        case .chord(let c): duration = c.duration
        default:
            throw SheetMusicError.invalidEdit(
                reason: "DeleteVoiceElement: element at \(location) "
                    + "is not a chord or rest (\(original))")
        }
        score[location] = .rest(duration: duration)
        return ReplaceVoiceElement(at: location, with: original)
    }
}
