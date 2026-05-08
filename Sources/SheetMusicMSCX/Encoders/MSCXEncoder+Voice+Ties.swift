import Foundation
import SheetMusicCore
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
        voiceBarLength: Fraction
    ) -> TieLocation? {
        guard chord.notes.contains(where: { $0.tieForward != nil })
        else { return nil }
        let dur = chord.duration.asFraction
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
        prevVoiceTotal: Fraction?
    ) -> TieLocation? {
        guard chord.notes.contains(where: { $0.tieBack != nil }),
              let prevDur = previousChordDuration
        else { return nil }
        if isFirstChordOfVoice, let prevTotal = prevVoiceTotal {
            return .crossMeasure(measures: -1, fractions: prevTotal - prevDur)
        }
        return .sameMeasure(fractions: Fraction(
            numerator: -prevDur.numerator,
            denominator: prevDur.denominator
        ))
    }
}
