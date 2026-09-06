import SheetMusicFoundation

/// A uniform planning surface over the existing text-edit commands. The planner owns no session or cursor state;
/// hosts choose a kind, apply the returned command, and retain the returned anchor themselves.
public enum TextInputPlanner {
    public enum Kind: Sendable, CaseIterable, Equatable {
        case staffText
        case systemText
        case chordSymbol
        case rehearsalMark
    }

    /// The text currently at `anchor` for this kind, or `nil` when there is none.
    public static func currentText(_ kind: Kind, at anchor: VoiceElementID, in score: Score) -> String? {
        switch kind {
        case .staffText:
            return SetStaffText.current(at: anchor, isSystemText: false, in: score)
        case .systemText:
            return SetStaffText.current(at: anchor, isSystemText: true, in: score)
        case .chordSymbol:
            return SetChordSymbol.current(at: anchor, in: score)?.name
        case .rehearsalMark:
            return RehearsalMarkLane.mark(in: score, measureIndex: anchor.measureIndex)?.text
        }
    }

    /// The command that writes `text` there, or removes it when `text` is `nil`.
    public static func command(_ kind: Kind, at anchor: VoiceElementID, text: String?) -> any EditCommand {
        switch kind {
        case .staffText:
            return SetStaffText(anchor: anchor, text: text, isSystemText: false)
        case .systemText:
            return SetStaffText(anchor: anchor, text: text, isSystemText: true)
        case .chordSymbol:
            return SetChordSymbol(at: anchor, name: text, harmonyType: .standard)
        case .rehearsalMark:
            if let text {
                return SetRehearsalMark(measureIndex: anchor.measureIndex, text: text)
            }
            return RemoveRehearsalMark(measureIndex: anchor.measureIndex)
        }
    }

    /// Where a host's commit-and-advance key goes next, or `nil` at the end.
    public static func nextAnchor(_ kind: Kind, after anchor: VoiceElementID, in score: Score) -> VoiceElementID? {
        switch kind {
        case .staffText, .systemText, .chordSymbol:
            return ElementNavigator.nextTimedElement(after: anchor, in: score)
        case .rehearsalMark:
            let nextMeasure = anchor.measureIndex + 1
            let beforeFirst = VoiceElementID(
                staff: anchor.staff,
                measureIndex: nextMeasure,
                voiceIndex: anchor.voiceIndex,
                elementIndex: -1,
            )
            guard let next = ElementNavigator.nextTimedElement(after: beforeFirst, in: score),
                  next.measureIndex == nextMeasure
            else { return nil }
            return next
        }
    }
}
