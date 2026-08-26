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

    /// The part ids the current `partIndexMapping` is measured from — the score's ids at `init`, re-taken by
    /// `consumePartIndexMapping()`.
    private var partIDBaseline: [String]

    public init(score: Score) {
        editor = ScoreEditor(score: score)
        partIDBaseline = score.parts.map(\.id)
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

    // MARK: - Part-index mapping

    /// Where every part that existed at the last consume point (or at `init`) is NOW: `nil` means it was removed.
    ///
    /// A host keys per-part state — a mixer strip's volume, a staff's collapsed flag, a per-instrument SoundFont —
    /// by part INDEX, and an add / remove / move renumbers underneath it. This is the map to migrate that state
    /// through, taken cumulatively over every intent applied since the baseline rather than per edit, so a host can
    /// read it once when it is ready to write rather than following along with each step.
    ///
    /// Derived by diffing `Part.id` snapshots, which is what makes undo and redo free: an undone removal puts the
    /// same id back, and the diff says so without anything having to track the inverse.
    ///
    /// **Duplicate ids in the baseline yield the identity mapping.** A malformed file can carry two parts sharing
    /// an id, and `firstIndex(of:)` cannot tell them apart — the answer would be a plausible-looking lie that moves
    /// one part's preferences onto another. Reporting identity makes the host skip the migration instead, which
    /// leaves its state pointing where it already pointed. Losing a migration is recoverable; corrupting the
    /// preferences it was migrating is not.
    public var partIndexMapping: [Int: Int?] {
        let baseline = partIDBaseline
        guard Set(baseline).count == baseline.count else {
            return Dictionary(uniqueKeysWithValues: baseline.indices.map { ($0, Optional($0)) })
        }
        let current = editor.score.parts.map(\.id)
        return Dictionary(
            uniqueKeysWithValues: baseline.enumerated().map { ($0.offset, current.firstIndex(of: $0.element)) },
        )
    }

    /// Whether `partIndexMapping` says nothing moved and nothing went away — the case a host can skip entirely.
    ///
    /// A part APPENDED past the end leaves this true: it renumbers none of the parts the baseline knew about, so
    /// there is nothing to migrate.
    public var isPartMappingIdentity: Bool {
        partIndexMapping.allSatisfy { $0.value == $0.key }
    }

    /// Re-baselines the mapping to the current parts, so the next `partIndexMapping` is measured from here.
    ///
    /// Call it after acting on a mapping. Until it is called the mapping keeps accumulating, which is deliberate:
    /// a host that reads it three edits later still gets one map from the state it last wrote.
    public func consumePartIndexMapping() {
        partIDBaseline = editor.score.parts.map(\.id)
    }
}
