import SheetMusicCore
import SheetMusicFoundation

extension MidiRenderer {
    /// How far swing pushes each sounding chord's onset, in ticks, keyed by the chord's
    /// representative `ScoreItemID` (note index 0 — what `PlaybackTimeline` stamps on a frame).
    ///
    /// Swing is a performance nuance the renderer applies to note-ons: an up-beat in a swung pair
    /// starts late by `(ratio - 50)/100` of the pair, and the down-beat before it is lengthened to
    /// match. It moves no bar line and no beat, so it never changes the tick↔seconds clock — which
    /// is why a caller wants the shifts on their own rather than folded into that clock. A cursor
    /// that ignores them steps onto a swung eighth up to a tenth of a beat before it is heard.
    ///
    /// Only sounding chords appear: a rest advances the tick cursor without a swing adjustment,
    /// exactly as in `renderVoiceElement`. Empty when the score has no swing in force anywhere.
    public static func swingOnsetShifts(score: Score) -> [SheetMusicCore.ScoreItemID: Int] {
        let division = score.division
        let swingMaps = collectSwingMaps(score: score, division: division)
        guard swingMaps.contains(where: { $0.initial.isOn || $0.entries.contains { $0.state.isOn } })
        else { return [:] }

        var shifts: [SheetMusicCore.ScoreItemID: Int] = [:]
        for (staffIndex, entry) in score.allStaves.enumerated() {
            let swingMap = staffIndex < swingMaps.count ? swingMaps[staffIndex] : SwingMap.empty
            let measures = entry.staff.measures
            let measureDurations = measures.effectiveMeasureDurations()
            var measureBase = 0
            for (measureIndex, measure) in measures.enumerated() {
                let measureDuration = measureIndex < measureDurations.count
                    ? measureDurations[measureIndex]
                    : Fraction(numerator: 4, denominator: 4)
                for (voiceIndex, voice) in measure.voices.enumerated() {
                    for (elementIndex, shift) in voiceShifts(
                        in: voice, measureBase: measureBase, measureDuration: measureDuration,
                        division: division, swingMap: swingMap,
                    ) {
                        shifts[.note(NoteID(
                            staff: entry.address,
                            measureIndex: measureIndex,
                            voiceIndex: voiceIndex,
                            elementIndex: elementIndex,
                            noteIndexInChord: 0,
                        ))] = shift
                    }
                }
                measureBase += measureTicks(
                    measure: measure, division: division, measureDuration: measureDuration,
                )
            }
        }
        return shifts
    }

    /// One voice's swung chords, as `(elementIndex, onsetShift)`. Mirrors `renderVoiceElement`'s
    /// own walk: the running tick advances by each chord's NOMINAL duration — including a rest's,
    /// which takes no adjustment of its own — so the swing grid stays aligned to the bar.
    private static func voiceShifts(
        in voice: Voice,
        measureBase: Int,
        measureDuration: Fraction,
        division: Int,
        swingMap: SwingMap,
    ) -> [(Int, Int)] {
        // Absolute NOTATED tick, which is what the swing grid and the swing map are both keyed on.
        // (`renderVoice` runs the same walk in unrolled ticks and converts back with
        // `originalTickDelta`; here there is nothing to convert.)
        var localTick = measureBase
        var result: [(Int, Int)] = []
        for (elementIndex, element) in voice.elements.enumerated() {
            switch element {
            case let .locationShift(delta):
                localTick += delta.ticks(division: division)
            case let .chord(chord) where chord.notes.isEmpty:
                localTick += chord.duration.resolved(in: measureDuration).ticks(division: division)
            case let .chord(chord):
                let chordTicks = chord.duration
                    .resolved(in: measureDuration)
                    .ticks(division: division)
                let adjust = swingAdjustment(
                    startTick: localTick,
                    chordTicks: chordTicks,
                    prevChordTicks: previousChordTicks(
                        in: voice.elements, before: elementIndex,
                        measureDuration: measureDuration, division: division,
                    ),
                    nextChordTicks: nextChordTicks(
                        in: voice.elements, after: elementIndex,
                        measureDuration: measureDuration, division: division,
                    ),
                    isInTuplet: isChordInTuplet(
                        elementIndex: elementIndex, voiceTuplets: voice.tuplets,
                    ),
                    state: swingMap.state(atTick: localTick),
                )
                if adjust.onsetShift != 0 {
                    result.append((elementIndex, adjust.onsetShift))
                }
                localTick += chordTicks
            default:
                break
            }
        }
        return result
    }
}
