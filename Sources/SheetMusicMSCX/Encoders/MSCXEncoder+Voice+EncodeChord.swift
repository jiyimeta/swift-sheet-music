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
        let unscaled = try unscaledDuration(chord.duration, in: activeTuplets)
        // Rebuild must forward every chord-attached field — new fields
        // added to `Chord.init` must be propagated here too, otherwise
        // un-scaling silently drops them from the encoded XML.
        let unscaledChord = Chord(
            duration: unscaled,
            notes: chord.notes,
            arpeggio: chord.arpeggio,
            lyrics: chord.lyrics,
            articulations: chord.articulations,
            tremolo: chord.tremolo,
        )
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
