import SheetMusicFoundation

/// `ScoreEditSession`'s planning half: the pure `EditIntent` → `EditCommand` translation, with no session state
/// involved.
///
/// Split out of `ScoreEditSession.swift` when that file reached SwiftLint's 400-line budget. The seam is a real one
/// rather than an arbitrary cut: everything here is `static` and reads only the score it is handed, so a planner can
/// be exercised — and reasoned about — without an editor, an undo stack or a refusal to record. `ScoreEditSession`
/// itself keeps the stateful surface (`apply`, `undo`, `redo`, `lastRefusal`, the part-index mapping).
extension ScoreEditSession {
    /// Real composites bundle at most two atomic edits (a range op wrapping two sub-commands). This is a bound on
    /// how deep a nested `.composite` may recurse before `command(for:in:depth:)` refuses it outright, so a
    /// malformed or pathological intent tree can't be planned into a stack overflow instead of a clean refusal —
    /// the same limit `CompositeIntentWire.decoded` enforces on the wire side of this same recursion.
    private static let maxCompositeIntentDepth = 8

    /// Plans an intent against `score`. `nil` when the intent has nothing to do — an empty composite, a composite
    /// whose members all planned to nothing, or a `.movePart` that would not move anything. Throws when a nested
    /// `.composite` exceeds `maxCompositeIntentDepth`.
    static func command( // swiftlint:disable:this function_body_length
        for intent: EditIntent, in score: Score, depth: Int,
    ) throws -> (any EditCommand)? {
        switch intent {
        case let .inputNote(location, pitch, tpc, duration):
            return inputNoteCommand(at: location, pitch: pitch, tpc: tpc, duration: duration, in: score)
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
                throw SheetMusicError.invalidEdit(EditRefusal(
                    operation: "composite",
                    reason: .compositeTooDeep(limit: maxCompositeIntentDepth),
                ))
            }
            // Each member is planned against the score AS THE MEMBERS BEFORE IT LEFT IT, not against the score the
            // composite started from. A composite is a sequence, and every planner that reads the score — the
            // cross-bar planners, the `.measure` promotion, the full-measure collapse — is asking about the state
            // its own command will meet. Planning them all against the opening state answers those questions about
            // a score that will no longer exist by the time they run: a write into a voice a previous member
            // creates would ask "does this bar fill from beat one?" of a voice that is not there yet, and promote a
            // quarter rest to a measure rest on the strength of it.
            //
            // The scratch score is a value copy and never leaves this function; a member that throws while being
            // planned forward is left to throw again for real at apply time, where the refusal is recorded.
            let commands = try compositeCommands(for: intents, in: score, depth: depth)
            guard let first = commands.first else { return nil }
            guard commands.count > 1 else { return first }
            return CompositeEditCommand(commands: commands, location: first.affectedLocation)
        case let .writeNote(location, pitch, tpc, duration):
            return try writeNoteCommand(at: location, pitch: pitch, tpc: tpc, duration: duration, in: score)
        case let .writeRest(location, duration):
            return writeRestCommand(at: location, duration: duration, in: score)
        case .insertMeasure, .deleteMeasure, .addPart, .removePart, .movePart, .setPartNames,
             .setKeySignature, .removeKeySignature, .setRehearsalMark, .removeRehearsalMark:
            // The intents that change the score's SHAPE rather than its notes — measure columns, parts, what a bar
            // declares, and the rehearsal mark it carries. Factored into `structuralCommand` for the same reason the
            // six note edits below are factored into `directNoteEditCommand`: to keep this switch under SwiftLint's
            // body budget.
            return try structuralCommand(for: intent, in: score)
        case let .setTimeSignature(measureIndex, numerator, denominator):
            // Dispatched from this switch rather than folded into `structuralCommand` alongside the other
            // shape-changing intents: that fold is a chain of `if case`s ending in `return nil`, where a case
            // nobody added would resolve to "nothing to apply" instead of failing to build.
            return setTimeSignatureCommand(
                at: measureIndex, numerator: numerator, denominator: denominator, in: score,
            )
        case let .removeTimeSignature(measureIndex):
            return removeTimeSignatureCommand(at: measureIndex, in: score)
        // Drum note entry's three additions — a voice to write into, a slot at the caret's tick, and the note's
        // head. Factored into `drumInputCommand` for the same reason the shape-changing intents are factored into
        // `structuralCommand`, and written on one line for the same reason again: this switch is at the body
        // budget, and a case per intent would put it over.
        case .createVoice, .splitRest, .setNoteHead, .setDrumsetEntry: return drumInputCommand(for: intent, in: score)
        case let .setNotePitch(location, pitch, tpc, accidental):
            return retuneCommand(at: location, pitch: pitch, tpc: tpc, accidental: accidental, in: score)
        case .setAccidental, .addNoteToChord, .removeNoteFromChord, .setTie, .createTuplet, .removeTuplet:
            // These six note-editing intents each map straight onto their `EditCommand`, with no cross-bar or
            // collapse planning involved — unlike `.inputNote` / `.setRestDuration` / `.delete` above, which route
            // through planners. Factored into `directNoteEditCommand` to keep this switch under SwiftLint's line
            // budget, not because they belong to a different subsystem.
            return try directNoteEditCommand(for: intent)
        case .setLayoutBreak, .setBarLine, .setRepeatBarLines, .setMeasureRepeat, .moveToVoice:
            return structuralParityCommand(for: intent, in: score)
        case .transposeRange, .addIntervalToSelection, .deleteRange, .setAccidentalsInRange, .setDurationInRange,
             .respellRange:
            return rangeCommand(for: intent, in: score)
        case .setClef, .removeClef, .setTempo, .setStaffText, .setDynamic, .setFermata, .setBreath, .setJumps,
             .setMarkers:
            return markCommand(for: intent, in: score)
        }
    }

    /// A composite's members, each planned against the score AS THE MEMBERS BEFORE IT LEFT IT rather than against
    /// the score the composite started from.
    ///
    /// A composite is a sequence, and every planner that reads the score — the cross-bar planners, the `.measure`
    /// promotion, the full-measure collapse — is asking about the state its own command will meet. Planning them
    /// all against the opening state answers those questions about a score that will no longer exist by the time
    /// they run: a write into a voice a previous member creates would ask "does this bar fill from beat one?" of a
    /// voice that is not there yet, and promote a quarter rest to a measure rest on the strength of it.
    ///
    /// The scratch score is a value copy and never leaves this function. A member that throws while being planned
    /// forward is left to throw again for real at apply time, where the refusal is recorded and the composite rolls
    /// back.
    private static func compositeCommands(
        for intents: [EditIntent], in score: Score, depth: Int,
    ) throws -> [any EditCommand] {
        var working = score
        var commands: [any EditCommand] = []
        for intent in intents {
            guard let planned = try command(for: intent, in: working, depth: depth + 1) else { continue }
            _ = try? planned.apply(to: &working)
            commands.append(planned)
        }
        return commands
    }

    /// `.inputNote`: write a note into a rest slot, re-timing the slot to `duration` in the same undo step.
    ///
    /// Inside a tuplet the length change is refused by the engine, and a composite is all-or-nothing, so that
    /// refusal would take the note write down with it — the second and later notes of a triplet would simply never
    /// appear. There the note is written at whatever length the slot already has.
    ///
    /// The cross-bar planner is asked FIRST, before the composite is built: `SetRestDuration` refuses for four
    /// reasons besides tuplets, and every one of those refusals would otherwise take the note write with it.
    private static func inputNoteCommand(
        at location: RestID, pitch: Int, tpc: Int, duration: NoteDuration?, in score: Score,
    ) -> any EditCommand {
        let write = InputNote(at: location, pitch: pitch, tpc: tpc)
        guard let duration else { return write }
        let slot = VoiceElementID(location)
        guard !isInTuplet(slot, in: score) else { return write }
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
    }

    /// `.writeRest`: make the slot a rest of `duration`, whatever is in it now.
    ///
    /// Three shapes:
    ///
    /// 1. The length outruns the bar — a run of rests across the barline, spelled by the same planner a note uses
    ///    (minus the ties, which rests don't take). The plan REPLACES the slot's contents, so it subsumes the
    ///    delete: issuing a separate one would re-splice what the plan just laid down.
    /// 2. The slot already holds a rest — the re-time alone, which is exactly `.setRestDuration`.
    /// 3. The slot holds a note — the delete paired with the re-time, as one composite so it is one undo step.
    ///
    /// That delete is the PLAIN one. Routing it through `FullMeasureRestCollapse` — what `.delete` does — would
    /// collapse a bar this empties into a single measure rest, throwing away both the length the caller just stated
    /// and the bar's remaining subdivision. `.delete` keeps the collapse because ⌫ means "empty this"; this intent
    /// means "make it this long", and the two want opposite spellings.
    ///
    /// A bar-filling length still lands as `.measure`, via `RestDurationPromotion` — the same rule reached from the
    /// other direction. The promotion is computed against the pre-delete score, which gives the same answer: it asks
    /// whether any chord PRECEDES the slot, and the slot itself is not among those.
    ///
    /// `nil` when the slot holds no timed element at all — a clef or a time signature is not something to rest over.
    private static func writeRestCommand(
        at location: VoiceElementID, duration: NoteDuration, in score: Score,
    ) -> (any EditCommand)? {
        guard case let .chord(current)? = score[location] else { return nil }
        if let plan = CrossBarInputPlanner.plan(.rest, duration: duration, at: location, in: score) {
            return CompositeEditCommand(commands: plan.commands, location: plan.head)
        }
        let retime = SetRestDuration(
            at: location, duration: RestDurationPromotion.promoted(duration, at: location, in: score),
        )
        guard !current.notes.isEmpty else { return retime }
        return CompositeEditCommand(
            commands: [DeleteVoiceElement(at: location), retime], location: location,
        )
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
                throw SheetMusicError.invalidEdit(EditRefusal(
                    operation: "createTuplet",
                    reason: .invalidTupletRatio(
                        actualNotes: actualNotes,
                        normalNotes: normalNotes,
                    ),
                ))
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
            throw SheetMusicError.invalidEdit(EditRefusal(
                operation: "writeNote",
                reason: .wrongElementKind(at: location, expected: .chord),
            ))
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
