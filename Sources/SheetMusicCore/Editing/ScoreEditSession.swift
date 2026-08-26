import SheetMusicFoundation

/// One editing session over a score: turns an `EditIntent` into the commands that realize it and applies them as a
/// single undoable step.
///
/// This is the choke point both platforms share. iOS drives one directly; an Android host drives an authoritative one
/// in its own image and relays each applied intent to a mirror session behind the score handle, so the two stay
/// byte-identical while only the layout is recomputed.
///
/// Not `@MainActor` and not `Sendable` — hold one per isolation domain. See `ScoreEditor` for why.
///
/// The `EditIntent` → `EditCommand` translation itself lives in `ScoreEditSession+Planning.swift`: it is entirely
/// `static` and reads only the score it is handed, so it splits off this file cleanly. What stays here is the
/// stateful surface — `apply`, `undo` / `redo`, `lastRefusal`.
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

    /// Why the most recent `apply` call returned `false`, or `nil` before the first call and after the most recent
    /// one succeeded. Structured so a host UI can switch over the refusal rather than matching English.
    public private(set) var lastRefusal: EditRefusal?

    /// Applies `intent` as one undo step. Returns `false` when the intent names nothing the score can act on, or
    /// when a sub-command refuses partway through a composite. In the latter case `CompositeEditCommand` rolls back
    /// what it already applied via each sub-command's inverse — but that rollback runs with `try?`, so it is
    /// best-effort, not a guarantee backed by the engine: a rollback failure is swallowed rather than surfaced. A
    /// refused intent is not itself an error: the caller simply has nothing to relay, so a mirror session stays in
    /// step by doing nothing too.
    @discardableResult
    public func apply(_ intent: EditIntent) -> Bool {
        let planned: (any EditCommand)?
        do {
            planned = try Self.command(for: intent, in: editor.score, depth: 0)
        } catch {
            lastRefusal = Self.refusal(for: error, operation: "apply")
            return false
        }
        guard let planned else {
            lastRefusal = EditRefusal(operation: "apply", reason: .nothingToApply)
            return false
        }
        do {
            try editor.apply(Self.renotatingAccidentals(planned, from: editor.score))
        } catch {
            lastRefusal = Self.refusal(for: error, operation: "apply")
            return false
        }
        lastRefusal = nil
        return true
    }

    /// `command` with the accidental-glyph repairs its own edit makes necessary bundled onto it, as one undo step —
    /// or `command` untouched when it needs none (the common case) or when the engine would refuse it anyway.
    ///
    /// A stored glyph is only true relative to what precedes it in the bar, so any edit that changes a pitch, adds a
    /// note, or removes one can leave a LATER note in that bar saying the wrong thing. MuseScore re-runs its
    /// accidental state over the measure after every such edit; `MeasureAccidentals` is that pass, and this is where
    /// it hangs. Both images run it, from the same scalars, which is why the repairs never have to cross the wire.
    ///
    /// The repairs are planned against the POST-edit score, so the command is applied to a throwaway copy first.
    /// That copy is also what tells us a refused edit needs no repairs at all.
    private static func renotatingAccidentals(_ command: any EditCommand, from score: Score) -> any EditCommand {
        var preview = score
        guard (try? command.apply(to: &preview)) != nil else { return command }
        let repairs = MeasureAccidentals.renotationCommands(in: preview, changedFrom: score)
        guard !repairs.isEmpty else { return command }
        return CompositeEditCommand(commands: [command] + repairs, location: command.affectedLocation)
    }

    /// Preserves an edit refusal directly and wraps any escaped foreign error.
    private static func refusal(for error: Error, operation: String) -> EditRefusal {
        guard case let SheetMusicError.invalidEdit(refusal) = error else {
            return EditRefusal(
                operation: operation,
                reason: .unexpected(description: String(describing: error)),
            )
        }
        return refusal
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
}
