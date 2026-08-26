import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension Voice {
    /// Build the `<Spanner type="Tie"><next><location>` payload
    /// for a chord with `tieForward` set. MuseScore encodes the
    /// `<location>` as a played-tick delta from source to target,
    /// expressed as `(measures, fractions)` whose sum equals the
    /// delta. For ties to the immediately following chord:
    ///  - same bar: `<fractions>source.duration</fractions>` only
    ///  - cross bar: `<measures>1</measures><fractions>(source.duration - barLength)</fractions>`
    func forwardTieLocation(
        chord: Chord,
        isLastChordOfVoice: Bool,
        voiceBarLength: Fraction,
    ) -> TieLocation? {
        guard chord.notes.contains(where: { $0.tieForward != nil })
        else { return nil }
        return forwardTieDelta(
            chord: chord,
            isLastChordOfVoice: isLastChordOfVoice,
            voiceBarLength: voiceBarLength,
        )
    }

    /// The location itself, without the "does this chord actually carry
    /// a forward tie?" guard. Split out because a `graceNotesAfter`
    /// chord ties forward into the chord *after* its parent, so it needs
    /// its parent's forward delta even when the parent's own notes carry
    /// no tie — a grace shares its parent's tick, so the delta is
    /// identical. See `GraceChord.encode`.
    func forwardTieDelta(
        chord: Chord,
        isLastChordOfVoice: Bool,
        voiceBarLength: Fraction,
    ) -> TieLocation {
        // A `.measure` rest never carries a tie, so this resolution
        // is unreachable for measure-rests in practice. We still
        // resolve here so the call is uniformly trap-safe regardless
        // of upstream invariants.
        let dur = chord.duration.resolved(in: voiceBarLength).asFraction
        return isLastChordOfVoice
            ? .crossMeasure(measures: 1, fractions: dur - voiceBarLength)
            : .sameMeasure(fractions: dur)
    }

    /// Build the `<Spanner type="Tie"><prev><location>` payload
    /// for a chord with `tieBack` set. Mirrors `forwardTieLocation`
    /// — same-bar back ties carry `-prev_chord_duration`;
    /// cross-bar back ties carry `(measures: -1, fractions: prev_voice_total - prev_chord_duration)`.
    func backwardTieLocation(
        chord: Chord,
        isFirstChordOfVoice: Bool,
        previousChordDuration: Fraction?,
        prevVoiceTotal: Fraction?,
    ) -> TieLocation? {
        guard chord.notes.contains(where: { $0.tieBack != nil })
        else { return nil }
        return backwardTieDelta(
            isFirstChordOfVoice: isFirstChordOfVoice,
            previousChordDuration: previousChordDuration,
            prevVoiceTotal: prevVoiceTotal,
        )
    }

    /// The location itself, without the "does this chord actually carry
    /// a backward tie?" guard — the `graceNotesBefore` counterpart of
    /// `forwardTieDelta`. Still `nil` when there is no previous chord to
    /// point at.
    func backwardTieDelta(
        isFirstChordOfVoice: Bool,
        previousChordDuration: Fraction?,
        prevVoiceTotal: Fraction?,
    ) -> TieLocation? {
        guard let prevDur = previousChordDuration else { return nil }
        if isFirstChordOfVoice, let prevTotal = prevVoiceTotal {
            return .crossMeasure(measures: -1, fractions: prevTotal - prevDur)
        }
        return .sameMeasure(fractions: Fraction(
            numerator: -prevDur.numerator,
            denominator: prevDur.denominator,
        ))
    }
}
