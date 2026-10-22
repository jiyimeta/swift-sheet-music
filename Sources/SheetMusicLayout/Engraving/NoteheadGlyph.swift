import SheetMusicCore

/// SMuFL codepoint selector for noteheads.
///
/// Resolves `(duration, headType, stemUp)` to a SMuFL codepoint by
/// looking up the head token in `NoteHeadGroup`, then selecting the
/// appropriate glyph name from the SMuFL table via `NoteHeadGroup.symName`.
/// Unknown or `nil` head types fall back to the standard notehead family.
///
/// MuseScore's custom group (`"custom"`) names no glyphs of its own: a drum note in it draws its kit's glyph for the
/// duration (`kitNoteheads`, `Note::noteHead` → `Drumset::noteHeads`), and draws normal with no kit to read, as on a
/// pitched staff.
public enum NoteheadGlyph {
    public static func codepoint(
        duration: NoteDuration, headType: String?, stemUp: Bool, kitNoteheads: DrumsetNoteheads? = nil,
    ) -> UInt32 {
        let kind: NoteHeadKind
        switch duration {
        // MuseScore heads a long with the breve's head, and gives it a stem (`TDuration::headType` / `hasStem`).
        case .long, .breve: kind = .doubleWhole
        case .whole: kind = .whole
        case .half: kind = .half
        default: kind = .quarter
        }
        if headType == "custom", let kitNoteheads, let cp = SMuFLCodepoint.byName(name(in: kitNoteheads, for: kind)) {
            return cp
        }
        if let token = headType, let group = NoteHeadGroup.from(token: token) {
            let name = NoteHeadGroup.symName(group: group, kind: kind, stemUp: stemUp)
            if name != "noSym", let cp = SMuFLCodepoint.byName(name) { return cp }
        }
        // Fallback: standard notehead family.
        switch kind {
        case .doubleWhole: return SMuFLCodepoint.noteheadDoubleWhole
        case .whole: return SMuFLCodepoint.noteheadWhole
        case .half: return SMuFLCodepoint.noteheadHalf
        default: return SMuFLCodepoint.noteheadBlack
        }
    }

    private static func name(in kitNoteheads: DrumsetNoteheads, for kind: NoteHeadKind) -> String {
        switch kind {
        case .whole: kitNoteheads.whole
        case .half: kitNoteheads.half
        case .quarter: kitNoteheads.quarter
        case .doubleWhole: kitNoteheads.breve
        }
    }
}
