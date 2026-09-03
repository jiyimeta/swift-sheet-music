import SheetMusicFoundation

/// `ScoreEditSession`'s planning half for the parity project's mark intents (41…49) and its chord symbol (73), an
/// adjacent mark in every respect a planner cares about. Its own file for the reason `+RangePlanning.swift`
/// exists: `+Planning.swift` sits at its line budget.
///
/// Every planner here follows the standing rule: an intent that restates what the score already says plans to
/// `nil` (`.nothingToApply`), never to a self-restoring undo entry. Each reads the score through the command's
/// own `current…` accessor, so "already says" is decided by the same lookup the command's `apply` performs.
/// Range and kind refusals stay in the commands' `apply`, so a command built directly answers the same way.
extension ScoreEditSession {
    static func markCommand(for intent: EditIntent, in score: Score) -> (any EditCommand)? {
        switch intent {
        case let .setClef(target, clef):
            let existing = AdjacentElementSlot.find(.before, of: target, in: score) {
                if case .clef = $0 { true } else { false }
            }.flatMap { index -> String? in
                guard case let .clef(current)? = score[target.withElementIndex(index)] else { return nil }
                return current.concertClefType
            }
            return existing == clef.rawType ? nil : SetClef(before: target, clef: clef)
        case let .removeClef(location):
            return RemoveClef(at: location)
        case let .setTempo(anchor, marking):
            return SetTempo.current(at: anchor, in: score) == marking ? nil : SetTempo(anchor: anchor, marking: marking)
        case let .setStaffText(anchor, text, isSystemText):
            // Trimmed for the comparison only — an empty result is the command's `.emptyStaffText` to raise.
            let trimmed = text?.trimmingWhitespaceAndNewlines()
            let current = SetStaffText.current(at: anchor, isSystemText: isSystemText, in: score)
            return current == trimmed ? nil : SetStaffText(anchor: anchor, text: text, isSystemText: isSystemText)
        case let .setDynamic(location, subtype):
            let current = SetDynamic.current(at: location, in: score)?.subtype
            return current == subtype ? nil : SetDynamic(at: location, subtype: subtype)
        case let .setFermata(location, subtype, timeStretch):
            let current = SetFermata.current(at: location, in: score)
            let same = current?.subtype == subtype && (subtype == nil || current?.timeStretch == timeStretch)
            return same ? nil : SetFermata(at: location, subtype: subtype, timeStretch: timeStretch)
        case let .setBreath(location, kind, pause):
            let current = SetBreath.current(after: location, in: score)
            let same = current?.kind == kind && (kind == nil || current?.pause == pause)
            return same ? nil : SetBreath(after: location, kind: kind, pause: pause)
        case let .setJumps(measure, jumps):
            // `[Jump]?` against `[Jump]`: a column the score lacks reads `nil`, never equal, so the command is
            // returned and its `apply` raises `.targetNotFound` rather than the planner swallowing it.
            let current = score[measure: measure, staff: Score.canonicalStaff]?.jumps
            return current == jumps ? nil : SetJumps(at: measure, jumps: jumps)
        case let .setMarkers(measure, markers):
            let current = score[measure: measure, staff: Score.canonicalStaff]?.markers
            return current == markers ? nil : SetMarkers(at: measure, markers: markers)
        case let .setChordSymbol(location, name, harmonyType):
            // Trimmed for the comparison only — an empty result is the command's `.emptyChordSymbol` to raise. A
            // file-authored symbol still carrying a root or bass is never a restatement: the command nils both,
            // and `HarmonyRendering.displayedName` prefixes the root's letter to `name` only while one stands.
            let current = SetChordSymbol.current(at: location, in: score)
            guard let name else {
                return current == nil ? nil : SetChordSymbol(at: location, name: nil, harmonyType: harmonyType)
            }
            let trimmed = name.trimmingWhitespaceAndNewlines()
            let same = current.map {
                $0.name == trimmed && $0.harmonyType == harmonyType && $0.rootTpc == nil && $0.bassTpc == nil
            } ?? false
            return same ? nil : SetChordSymbol(at: location, name: name, harmonyType: harmonyType)
        default:
            // Reached only through `command(for:in:depth:)`'s grouped case, which already narrows the intent;
            // the `default` exists because that narrowing is a `case` list, not a type.
            return nil
        }
    }
}
