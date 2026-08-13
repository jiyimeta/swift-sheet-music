import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Voice {
    /// Build the `<Chord>` / `<Rest>` element for one chord case of the
    /// element switch. Factored out of `encode(element:…)` so that
    /// dispatch fits within the function-body-length budget; carries
    /// the same `staffGroup` / `voiceIndex` threading needed for
    /// percussion-v3 stem direction and default note head emission.
    func encodeChord(
        chord: Chord,
        activeTuplets: [Tuplet],
        previousChordDuration: Fraction?,
        isFirstChordOfVoice: Bool,
        isLastChordOfVoice: Bool,
        prevVoiceTotal: Fraction?,
        voiceBarLength: Fraction,
        effectiveDuration: Fraction,
        injectedTremolo: Tremolo?,
        options: MSCXEncoderOptions,
        staffGroup: String,
        voiceIndex: Int,
    ) throws -> XMLTreeNode {
        // Copy-and-mutate rather than rebuilding from an explicit field
        // list: `Chord` is a value type, so every field survives by
        // construction and a future field added to `Chord` can't be
        // silently dropped here the way an explicit-list rebuild once was.
        var unscaledChord = chord
        unscaledChord.duration = try unscaledDuration(chord.duration, in: activeTuplets)
        let tieForward = forwardTieLocation(
            chord: chord,
            isLastChordOfVoice: isLastChordOfVoice,
            voiceBarLength: voiceBarLength,
        )
        let tieBack = backwardTieLocation(
            chord: chord,
            isFirstChordOfVoice: isFirstChordOfVoice,
            previousChordDuration: previousChordDuration,
            prevVoiceTotal: prevVoiceTotal,
        )
        return unscaledChord.notes.isEmpty
            ? unscaledChord.encodeAsRest(
                options: options, in: effectiveDuration,
            )
            : unscaledChord.encodeAsChord(
                tieForwardLocation: tieForward,
                tieBackLocation: tieBack,
                options: options,
                staffGroup: staffGroup,
                voiceIndex: voiceIndex,
                injectedTremolo: injectedTremolo,
            )
    }
}
