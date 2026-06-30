import SheetMusicCore

/// SMuFL codepoint selector for noteheads.
///
/// Resolves `(duration, headType, stemUp)` to a SMuFL codepoint by
/// looking up the head token in `NoteHeadGroup`, then selecting the
/// appropriate glyph name from the SMuFL table via `NoteHeadGroup.symName`.
/// Unknown or `nil` head types fall back to the standard notehead family.
public enum NoteheadGlyph {
    public static func codepoint(
        duration: NoteDuration, headType: String?, stemUp: Bool,
    ) -> UInt32 {
        let kind: NoteHeadKind
        switch duration {
        case .whole: kind = .whole
        case .half: kind = .half
        default: kind = .quarter
        }
        if let token = headType, let group = NoteHeadGroup.from(token: token) {
            let name = NoteHeadGroup.symName(group: group, kind: kind, stemUp: stemUp)
            if name != "noSym", let cp = SMuFLCodepoint.byName(name) { return cp }
        }
        // Fallback: standard notehead family.
        switch kind {
        case .whole: return SMuFLCodepoint.noteheadWhole
        case .half: return SMuFLCodepoint.noteheadHalf
        default: return SMuFLCodepoint.noteheadBlack
        }
    }
}
