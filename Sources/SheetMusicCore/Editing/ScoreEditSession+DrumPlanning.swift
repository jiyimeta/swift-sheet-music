import SheetMusicFoundation

/// The drum intents' planning half — `EditIntent` → `EditCommand` for `.createVoice`, `.splitRest`, `.setNoteHead`,
/// `.setDrumsetEntry` and `.revoiceDrumStaff`.
///
/// Split out of `ScoreEditSession+Planning.swift` for the reason the signature and rehearsal-mark planners are:
/// that file's switch is at SwiftLint's body budget, and these share a subject (making a drum key's whole
/// meaning reachable) rather than a mechanism.
extension ScoreEditSession {
    /// `default: return nil` here is the hazard `structuralCommand`'s doc comment warns about — an intent nobody
    /// wired would resolve to "nothing to apply" instead of failing to build. It is acceptable only because the
    /// caller's switch already narrows to these five cases (`createVoice`, `splitRest`, `setNoteHead`,
    /// `setDrumsetEntry`, `revoiceDrumStaff`); keep that `case` list and this one in step.
    ///
    /// `.revoiceDrumStaff` hands back the PLANNED COMPOSITE, as `.formatRhythms` does: it reports the first bar
    /// actually rewritten, which the command alone cannot know, and it spares the apply a second walk of the staff.
    /// A plan that throws falls back to the bare command, so the refusal is raised, and recorded, at apply time.
    static func drumInputCommand(
        for intent: EditIntent, in score: Score, ids: EIDAllocator,
    ) throws -> (any EditCommand)? {
        switch intent {
        case let .createVoice(staff, measureIndex, voiceIndex):
            // Nothing to do when the voice is already there. The refusals that DO belong to this intent — a gap
            // below the index, a measure that isn't there — stay in `CreateVoice.apply`, so one place states
            // each rule.
            guard score.parts.indices.contains(staff.partIndex),
                  score.parts[staff.partIndex].staves.indices.contains(staff.staffIndexInPart)
            else {
                return nil
            }
            let measures = score.parts[staff.partIndex].staves[staff.staffIndexInPart].measures
            guard measures.indices.contains(measureIndex),
                  voiceIndex >= measures[measureIndex].voices.count
            else {
                return nil
            }
            return CreateVoice(staff: staff, measureIndex: measureIndex, voiceIndex: voiceIndex)
        case let .splitRest(location, tickOffset):
            return SplitRest(at: location, tickOffset: tickOffset)
        case let .setNoteHead(location, headType):
            return SetNoteHead(at: location, headType: headType)
        case let .setDrumsetEntry(partIndex, pitch, entry):
            // Nothing to do when the kit already says exactly this — restating a row the score already carries
            // would push an undo entry that restores the score to itself, the rule `.setKeySignature` follows.
            guard score.parts.indices.contains(partIndex),
                  score.parts[partIndex].instrument.drumset[pitch] != entry
            else {
                return nil
            }
            return SetDrumsetEntry(partIndex: partIndex, pitch: pitch, entry: entry)
        case let .revoiceDrumStaff(staff, assignments, policy):
            // Later rows win, so a host can append an override without rewriting the list.
            let rows = assignments.map { ($0.pitch, $0.voiceIndex) }
            let command = RevoiceDrumStaff(
                staff: staff, voiceForPitch: Dictionary(rows) { _, last in last }, policy: policy,
            )
            do {
                return try command.plan(in: score, ids: ids)
            } catch {
                return command
            }
        default:
            return nil
        }
    }
}
