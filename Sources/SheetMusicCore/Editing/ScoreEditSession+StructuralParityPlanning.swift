import SheetMusicFoundation

/// `ScoreEditSession`'s planning half for the parity project's structural intents (30…34). Its own file for the
/// reason `+RehearsalMarkPlanning.swift` exists: `+Planning.swift` sits at its line budget, and these share nothing
/// with note entry beyond dispatch.
///
/// Every planner here follows the standing rule: an intent that restates what the score already says plans to
/// `nil` (`.nothingToApply`), never to a self-restoring undo entry. Range and emptiness refusals stay in the
/// commands' `apply`, so a command built directly answers the same way.
extension ScoreEditSession {
    static func structuralParityCommand(for intent: EditIntent, in score: Score) -> (any EditCommand)? {
        switch intent {
        case let .setLayoutBreak(measure, kind, enabled):
            let current = score[measure: measure, staff: Score.canonicalStaff].map { bar in
                switch kind {
                case .line: bar.lineBreak
                case .page: bar.pageBreak
                case .section: bar.sectionBreak
                }
            }
            return current == enabled ? nil : SetLayoutBreak(at: measure, kind: kind, enabled: enabled)
        case let .setBarLine(measure, style):
            let voiceRef = VoiceRef(staff: Score.canonicalStaff, measureIndex: measure.measureIndex, voiceIndex: 0)
            let voice = score[voice: voiceRef]
            let current = voice.flatMap { v -> String? in
                guard let index = SetBarLine.trailingBarLineIndex(in: v.elements),
                      case let .barLine(bar) = v.elements[index] else { return nil }
                return bar.subtype
            }
            let wanted: String? = style == .normal ? nil : style.rawValue
            return voice != nil && current == wanted ? nil : SetBarLine(at: measure, style: style)
        case let .setRepeatBarLines(measure, startRepeat, endRepeatCount):
            let bar = score[measure: measure, staff: Score.canonicalStaff]
            let unchanged = bar.map { $0.startRepeat == startRepeat && $0.endRepeatCount == endRepeatCount } ?? false
            return unchanged ? nil : SetRepeatBarLines(
                at: measure, startRepeat: startRepeat, endRepeatCount: endRepeatCount,
            )
        case let .setMeasureRepeat(measure, staff, numMeasures):
            let bar = score[measure: measure, staff: staff]
            if numMeasures == nil, bar != nil, bar?.measureRepeatCount == nil { return nil }
            return SetMeasureRepeat(at: measure, staff: staff, numMeasures: numMeasures)
        case let .moveToVoice(location, destination):
            return MoveToVoice(at: location, to: destination)
        default:
            // Reached only through `command(for:in:depth:)`'s grouped case, which already narrows the intent;
            // the `default` exists because that narrowing is a `case` list, not a type.
            return nil
        }
    }
}
