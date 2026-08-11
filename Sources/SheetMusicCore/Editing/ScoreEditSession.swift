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

    /// Why the most recent `apply` call returned `false`, or `nil` before the first call and after the most recent
    /// one succeeded. This is the only diagnostic available when a mirror session and its authoritative counterpart
    /// disagree about whether an edit landed — see `EditSessionBridge.nativeApplyEditIntent`'s doc comment on
    /// Android for why a refusal there is always worth investigating, never a benign no-op.
    public private(set) var lastRefusalReason: String?

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
            lastRefusalReason = Self.reason(for: error)
            return false
        }
        guard let planned else {
            lastRefusalReason = "intent resolved to nothing to apply"
            return false
        }
        do {
            try editor.apply(Self.renotatingAccidentals(planned, from: editor.score))
        } catch {
            lastRefusalReason = Self.reason(for: error)
            return false
        }
        lastRefusalReason = nil
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

    /// Unwraps `SheetMusicError.invalidEdit`'s `reason` directly rather than the error's generic description, so
    /// callers get the same message an `EditCommand` conformer authored, not `Optional(invalidEdit(reason:))`-shaped
    /// noise.
    private static func reason(for error: Error) -> String {
        guard case let SheetMusicError.invalidEdit(reason) = error else {
            return String(describing: error)
        }
        return reason
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

    /// Real composites bundle at most two atomic edits (a range op wrapping two sub-commands). This is a bound on
    /// how deep a nested `.composite` may recurse before `command(for:in:depth:)` refuses it outright, so a
    /// malformed or pathological intent tree can't be planned into a stack overflow instead of a clean refusal —
    /// the same limit `CompositeIntentWire.decoded` enforces on the wire side of this same recursion.
    private static let maxCompositeIntentDepth = 8

    /// Plans an intent against `score`. `nil` when the intent has nothing to do — an empty composite, or a composite
    /// whose members all planned to nothing. Throws when a nested `.composite` exceeds `maxCompositeIntentDepth`.
    private static func command(for intent: EditIntent, in score: Score, depth: Int) throws -> (any EditCommand)? {
        switch intent {
        case let .inputNote(location, pitch, tpc, duration):
            let write = InputNote(at: location, pitch: pitch, tpc: tpc)
            guard let duration else { return write }
            let slot = VoiceElementID(location)
            // A length change inside a tuplet is refused by the engine, and the refusal takes the note write down
            // with it — the second and later notes of a triplet simply never appear. Inside a tuplet the note is
            // written at whatever length the slot already has.
            guard !isInTuplet(slot, in: score) else { return write }
            // The armed length may overrun the barline. Ask the cross-bar planner FIRST: SetRestDuration refuses
            // for four reasons besides tuplets, and every one of those refusals would take the note write with it.
            // iOS only escapes the common case because this interception runs before the composite is built.
            if let plan = CrossBarInputPlanner.plan(
                .chord(Chord(duration: duration, notes: [Note(pitch: pitch, tpc: tpc)])),
                duration: duration, at: slot, in: score,
            ) {
                return CompositeEditCommand(commands: plan.commands, location: plan.head)
            }
            return CompositeEditCommand(
                commands: [SetRestDuration(at: slot, duration: duration), write],
                location: slot,
            )
        case let .setRestDuration(location, duration):
            // The rest key has the same cross-bar hole the note key does — mirrors Folino's
            // `EditorViewModel+Input.swift`'s `writeRest(over:in:)`, which asks the same planner before falling back
            // to a plain retime.
            if let plan = CrossBarInputPlanner.plan(.rest, duration: duration, at: location, in: score) {
                return CompositeEditCommand(commands: plan.commands, location: plan.head)
            }
            // A rest that fills its bar from beat one is spelled `.measure`, not the literal length — the same
            // promotion Folino's `restDuration(_:at:)` applies before this same fallback. `SetRestDuration` writes
            // whatever it's handed without judging that, so the fallback has to do the judging itself.
            return SetRestDuration(
                at: location, duration: RestDurationPromotion.promoted(duration, at: location, in: score),
            )
        case let .setChordDuration(location, duration):
            // The same cross-bar hole `.setRestDuration` has just above: the engine refuses any single-slot
            // lengthening that would cross a barline, so without this a host's length key reads as dead at every
            // barline — the very thing `CrossBarInputPlanner` was written to fix on the input side. Mirrors Folino's
            // `EditorViewModel+Input.swift`'s `retimeCrossingBarline`, which asks the same planner first.
            //
            // Planned from the chord ALREADY in the slot, not from a fresh one: `CrossBarInputPlanner.piece` clones
            // the content it is handed into every link, so passing anything else would drop the chord's other notes
            // (and its articulations, grace notes and ties) on the far side of the barline.
            //
            // No `.measure` promotion, unlike the rest case: `.measure` is a rest-only spelling — `MSCXEncoder` traps
            // rather than emit one on a chord (see `InputNote`'s doc comment).
            if case let .chord(current)? = score[location], !current.notes.isEmpty,
               let plan = CrossBarInputPlanner.plan(.chord(current), duration: duration, at: location, in: score)
            {
                return CompositeEditCommand(commands: plan.commands, location: plan.head)
            }
            return SetChordDuration(at: location, duration: duration)
        case let .delete(location):
            // A delete that empties its bar leaves ONE measure rest, not a hole — the same rule the write side
            // spells as `.measure` rather than `.whole`. `ReplaceVoiceElements.affectedLocation` always reports
            // element 0 (usually the clef or time signature the rest lands after, not the rest itself), so the
            // collapse's own `restElementIndex` is threaded through explicitly rather than trusted to the command's
            // own report — otherwise `lastAffectedLocation` would name the wrong element after every bar-emptying
            // delete, exactly as `FullMeasureRestCollapse.Plan.restElementIndex`'s doc comment warns.
            if let plan = FullMeasureRestCollapse.plan(deleting: location, in: score) {
                return CompositeEditCommand(
                    commands: [plan.command],
                    location: VoiceElementID(
                        staff: location.staff,
                        measureIndex: location.measureIndex,
                        voiceIndex: location.voiceIndex,
                        elementIndex: plan.restElementIndex,
                    ),
                )
            }
            return DeleteVoiceElement(at: location)
        case let .composite(intents):
            guard depth < maxCompositeIntentDepth else {
                throw SheetMusicError.invalidEdit(
                    reason: "composite nesting exceeds depth limit (\(maxCompositeIntentDepth))",
                )
            }
            let commands = try intents.compactMap { try command(for: $0, in: score, depth: depth + 1) }
            guard let first = commands.first else { return nil }
            guard commands.count > 1 else { return first }
            return CompositeEditCommand(commands: commands, location: first.affectedLocation)
        case let .writeNote(location, pitch, tpc, duration):
            return try writeNoteCommand(at: location, pitch: pitch, tpc: tpc, duration: duration, in: score)
        case let .setNotePitch(location, pitch, tpc, accidental):
            return retuneCommand(at: location, pitch: pitch, tpc: tpc, accidental: accidental, in: score)
        case .setAccidental, .addNoteToChord, .removeNoteFromChord, .setTie, .createTuplet, .removeTuplet:
            // These six note-editing intents each map straight onto their `EditCommand`, with no cross-bar or
            // collapse planning involved — unlike `.inputNote` / `.setRestDuration` / `.delete` above, which route
            // through planners. Factored into `directNoteEditCommand` to keep this switch under SwiftLint's line
            // budget, not because they belong to a different subsystem.
            return try directNoteEditCommand(for: intent)
        }
    }

    /// `.setNotePitch`: write the pitch onto `location` AND onto every note it is tied to, as one command.
    ///
    /// A tie chain is one sounding note written across several slots — that is what the curve tells a player, and what
    /// `MidiRenderer` already assumes when it carries the head's pitch through the chain. Retuning only the notehead
    /// the host named therefore produces something unplayable: two different pitches joined by a tie, sounding as the
    /// original pitch held. So the intent addresses the chain, however long it is and whichever member is named.
    ///
    /// The chain walk belongs HERE rather than in the host: an Android host would otherwise have to re-derive it in
    /// Kotlin against a score it only mirrors, which is the divergent second implementation this whole relay exists
    /// to avoid.
    ///
    /// The accidental goes on the chain's head alone. MuseScore prints none on the far side of a tie, and
    /// `MeasureAccidentals` deliberately skips tied-back notes when it renotates a measure — so a glyph written on one
    /// here would be nobody's left to remove.
    ///
    /// An untied note is a chain of one and comes back as a bare `SetNotePitch`, not a one-member composite, so the
    /// overwhelmingly common case is unchanged down to the command it produces.
    private static func retuneCommand(
        at location: NoteID, pitch: Int, tpc: Int, accidental: Accidental?, in score: Score,
    ) -> (any EditCommand)? {
        let chain = TiePlanner.tieChain(containing: location, in: score)
        // Empty means there is no note at `location` at all. Returning `nil` rather than a doomed command lets
        // `apply` report the refusal the same way it reports every other "nothing to do".
        guard !chain.isEmpty else { return nil }
        let commands: [any EditCommand] = chain.map { member in
            SetNotePitch(
                at: member, pitch: pitch, tpc: tpc,
                accidental: score[member]?.tieBack == nil ? accidental : nil,
            )
        }
        guard commands.count > 1 else { return commands[0] }
        return CompositeEditCommand(commands: commands, location: VoiceElementID(location))
    }

    /// The six intents that map directly onto an `EditCommand` with no planning step. Reached only via
    /// `command(for:in:depth:)`'s combined case above, so the `if case` chain below never needs to handle the six
    /// intents that function keeps for itself — an exhaustive `switch` here would have to fake-handle those too.
    private static func directNoteEditCommand(for intent: EditIntent) throws -> (any EditCommand)? {
        if case let .setAccidental(location, accidental) = intent {
            return SetAccidental(at: location, accidental: accidental)
        }
        if case let .addNoteToChord(location, pitch, tpc, accidental) = intent {
            return AddNoteToChord(at: location, pitch: pitch, tpc: tpc, accidental: accidental)
        }
        if case let .removeNoteFromChord(location) = intent {
            return RemoveNoteFromChord(at: location)
        }
        if case let .setTie(source, target, sourceTieForward, targetTieBack) = intent {
            return SetTie(
                from: source, to: target,
                sourceTieForward: sourceTieForward, targetTieBack: targetTieBack,
            )
        }
        if case let .createTuplet(location, actualNotes, normalNotes) = intent {
            // `CreateTuplet.init` enforces these with preconditions — traps, not throws. A relayed intent is
            // attacker-shaped data as far as this function is concerned, so the check has to happen here, before
            // construction, rather than letting the trap take the whole process down.
            guard actualNotes > 1, normalNotes > 0 else {
                throw SheetMusicError.invalidEdit(
                    reason: "createTuplet: ratio \(actualNotes):\(normalNotes) is not a tuplet",
                )
            }
            return CreateTuplet(at: location, actualNotes: actualNotes, normalNotes: normalNotes)
        }
        if case let .removeTuplet(location) = intent {
            return RemoveTuplet(at: location)
        }
        return nil
    }

    /// `.writeNote`: re-pitch the chord already in `location`, and re-time it to `duration` in the same undo step.
    ///
    /// Three shapes, in the order they are ruled out:
    ///
    /// 1. Nothing to re-time — no length asked for, the slot is already that length, or the slot is inside a tuplet,
    ///    where the member lengths are the tuplet's to decide and the engine refuses the change outright. A composite
    ///    is all-or-nothing, so that refusal would take the pitch write down with it; write the pitch alone.
    /// 2. The length outruns the bar — spell the note as a beat-aligned tied chain. The chain is planned from a FRESH
    ///    chord carrying the new pitch, not from the one in the slot: `CrossBarInputPlanner.piece` clones what it is
    ///    handed into every link, and that is precisely what a `.setChordDuration` + `.setNotePitch` pair cannot
    ///    reproduce — it would retune the head and leave the tail tied to it at the old pitch.
    /// 3. Otherwise — re-time and re-pitch as one composite.
    ///
    /// Throws when the slot holds a rest rather than a chord. That is `.inputNote`'s case, and re-routing quietly
    /// would make a relayed intent do something its name does not say.
    private static func writeNoteCommand(
        at location: VoiceElementID, pitch: Int, tpc: Int, duration: NoteDuration?, in score: Score,
    ) throws -> any EditCommand {
        guard case let .chord(current)? = score[location], !current.notes.isEmpty else {
            throw SheetMusicError.invalidEdit(reason: "writeNote: no chord at \(location)")
        }
        let repitch = SetNotePitch(
            at: NoteID(
                staff: location.staff,
                measureIndex: location.measureIndex,
                voiceIndex: location.voiceIndex,
                elementIndex: location.elementIndex,
                noteIndexInChord: 0,
            ),
            pitch: pitch, tpc: tpc,
        )
        guard let duration, current.duration != duration, !isInTuplet(location, in: score) else {
            return repitch
        }
        if let plan = CrossBarInputPlanner.plan(
            .chord(Chord(duration: duration, notes: [Note(pitch: pitch, tpc: tpc)])),
            duration: duration, at: location, in: score,
        ) {
            return CompositeEditCommand(commands: plan.commands, location: plan.head)
        }
        return CompositeEditCommand(
            commands: [SetChordDuration(at: location, duration: duration), repitch],
            location: location,
        )
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
