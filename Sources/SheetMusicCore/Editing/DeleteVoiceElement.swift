import Foundation

/// Replaces the chord or rest at `location` with a rest of the same
/// duration, preserving the measure's tick total. Used for the
/// "delete selection" UX on a chord (deletes the whole chord
/// including every note in it). Single-note removal from a chord
/// would be a separate command.
///
/// Behaviour by element kind:
///   - `.chord`: replaced with `.rest(Rest(duration: chord.duration))`.
///   - `.rest`:  replaced with itself (idempotent — still recorded
///               in the undo stack so a subsequent edit's undo path
///               stays consistent).
///   - any other element kind throws `SheetMusicError.invalidEdit`.
///
/// Inverse is a `ReplaceVoiceElement` that restores the original
/// element verbatim, so undo brings back the chord with all its
/// notes / accidentals / ties.
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
        case .rest(let r):  duration = r.duration
        default:
            throw SheetMusicError.invalidEdit(
                reason: "DeleteVoiceElement: element at \(location) "
                    + "is not a chord or rest (\(original))")
        }
        score[location] = .rest(Rest(duration: duration))
        return ReplaceVoiceElement(at: location, with: original)
    }
}
