import Foundation

/// One editing session over a score: turns an `EditIntent` into the commands that realize it and applies them as a
/// single undoable step.
///
/// This is the choke point both platforms share. iOS drives one directly; an Android host drives an authoritative one
/// in its own image and relays each applied intent to a mirror session behind the score handle, so the two stay
/// byte-identical while only the layout is recomputed.
///
/// Not `@MainActor` and not `Sendable` — hold one per isolation domain. See `ScoreEditor` for why.
public final class ScoreEditSession {
    private let editor: ScoreEditor

    public init(score: Score) {
        editor = ScoreEditor(score: score)
    }

    public var score: Score {
        editor.score
    }

    /// The voice slot the last applied / undone / redone intent touched, or `nil` before the first one lands.
    public var lastAffectedLocation: VoiceElementID? {
        editor.lastAffectedLocation
    }

    public var canUndo: Bool {
        editor.canUndo
    }

    public var canRedo: Bool {
        editor.canRedo
    }

    /// Applies `intent` as one undo step. Returns `false` — leaving the score untouched, by the engine's contract —
    /// when the intent names nothing the score can act on. A refused intent is not an error: the caller simply has
    /// nothing to relay, so a mirror session stays in step by doing nothing too.
    @discardableResult
    public func apply(_ intent: EditIntent) -> Bool {
        guard let command = Self.command(for: intent, in: editor.score) else { return false }
        do {
            try editor.apply(command)
        } catch {
            return false
        }
        return true
    }

    public func undo() -> Bool {
        guard editor.canUndo else { return false }
        do { try editor.undo() } catch { return false }
        return true
    }

    public func redo() -> Bool {
        guard editor.canRedo else { return false }
        do { try editor.redo() } catch { return false }
        return true
    }

    /// Plans an intent against `score`. `nil` when the intent has nothing to do — an empty composite, or a composite
    /// whose members all planned to nothing.
    private static func command(for intent: EditIntent, in score: Score) -> (any EditCommand)? {
        switch intent {
        case let .inputNote(location, pitch, tpc, duration):
            let write = InputNote(at: location, pitch: pitch, tpc: tpc)
            guard let duration else { return write }
            let slot = VoiceElementID(location)
            // A length change inside a tuplet is refused by the engine, and the refusal takes the note write down
            // with it — the second and later notes of a triplet simply never appear. Inside a tuplet the note is
            // written at whatever length the slot already has.
            guard !isInTuplet(slot, in: score) else { return write }
            return CompositeEditCommand(
                commands: [SetRestDuration(at: slot, duration: duration), write],
                location: slot,
            )
        case let .setRestDuration(location, duration):
            return SetRestDuration(at: location, duration: duration)
        case let .setChordDuration(location, duration):
            return SetChordDuration(at: location, duration: duration)
        case let .delete(location):
            return DeleteVoiceElement(at: location)
        case let .composite(intents):
            let commands = intents.compactMap { command(for: $0, in: score) }
            guard let first = commands.first else { return nil }
            guard commands.count > 1 else { return first }
            return CompositeEditCommand(commands: commands, location: first.affectedLocation)
        }
    }

    /// Whether `slot` sits inside a tuplet in `score`.
    private static func isInTuplet(_ slot: VoiceElementID, in score: Score) -> Bool {
        guard let staff = score[slot.staff],
              staff.measures.indices.contains(slot.measureIndex)
        else { return false }
        let voices = staff.measures[slot.measureIndex].voices
        guard voices.indices.contains(slot.voiceIndex) else { return false }
        return voices[slot.voiceIndex].tuplets.contains {
            slot.elementIndex >= $0.startIndex && slot.elementIndex <= $0.endIndex
        }
    }
}
