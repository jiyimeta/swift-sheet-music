import SheetMusicFoundation

/// `ScoreEditSession`'s planning half for the parity project's mark intents (41…49). Its own file for the reason
/// `+RangePlanning.swift` exists: `+Planning.swift` sits at its line budget.
extension ScoreEditSession {
    static func markCommand(for intent: EditIntent, in score: Score) -> (any EditCommand)? {
        switch intent {
        case let .setClef(target, clef):
            return SetClef(before: target, clef: clef)
        case let .removeClef(location):
            return RemoveClef(at: location)
        case let .setTempo(anchor, marking):
            return SetTempo(anchor: anchor, marking: marking)
        case let .setStaffText(anchor, text, isSystemText):
            return SetStaffText(anchor: anchor, text: text, isSystemText: isSystemText)
        case let .setDynamic(location, subtype):
            return SetDynamic(at: location, subtype: subtype)
        case let .setFermata(location, subtype, timeStretch):
            return SetFermata(at: location, subtype: subtype, timeStretch: timeStretch)
        case let .setBreath(location, kind, pause):
            return SetBreath(after: location, kind: kind, pause: pause)
        case let .setJumps(measure, jumps):
            return SetJumps(at: measure, jumps: jumps)
        case let .setMarkers(measure, markers):
            return SetMarkers(at: measure, markers: markers)
        default:
            // Reached only through `command(for:in:depth:)`'s grouped case, which already narrows the intent;
            // the `default` exists because that narrowing is a `case` list, not a type.
            return nil
        }
    }
}
