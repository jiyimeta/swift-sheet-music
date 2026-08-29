import SheetMusicFoundation

/// The drum note-entry intents' planning half — `EditIntent` → `EditCommand` for `.createVoice`, `.splitRest`
/// and `.setNoteHead`.
///
/// Split out of `ScoreEditSession+Planning.swift` for the reason the signature and rehearsal-mark planners are:
/// that file's switch is at SwiftLint's body budget, and these three share a subject (making a drum key's whole
/// meaning reachable) rather than a mechanism.
extension ScoreEditSession {
    /// `default: return nil` here is the hazard `structuralCommand`'s doc comment warns about — an intent nobody
    /// wired would resolve to "nothing to apply" instead of failing to build. It is acceptable only because the
    /// caller's switch already narrows to these three cases; keep that `case` list and this one in step.
    static func drumInputCommand(for intent: EditIntent, in score: Score) -> (any EditCommand)? {
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
        default:
            return nil
        }
    }
}
