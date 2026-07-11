import Foundation
import SheetMusicCore

extension MidiImporter {
    // MARK: - Drum voice splitting

    /// Split a drum measure into voice 0 (hands: cymbals, hi-hat,
    /// snare, toms) and voice 1 (feet: kick, low floor tom, pedal
    /// hi-hat) per `gmDrumVoiceIndex`. If voice 1 has no actual
    /// drum hits, omit it so the layout doesn't draw a redundant
    /// rest staff.
    static func drumVoices(
        measure: ImportMeasure,
        quantized: QuantizedMeasure,
        division: Int,
        maxDots: Int,
    ) -> [Voice] {
        let v0Pitches = pitchesInVoice(0, in: measure)
        let v1Pitches = pitchesInVoice(1, in: measure)
        var result: [Voice] = []
        // Voice 0 always emitted (even if empty — keeps clef + rests).
        result.append(voice(
            quantized: quantized,
            measure: filterMeasure(measure, keepingPitches: v0Pitches),
            division: division,
            isDrumTrack: true,
            maxDots: maxDots,
        ))
        if !v1Pitches.isEmpty {
            result.append(voice(
                quantized: quantized,
                measure: filterMeasure(measure, keepingPitches: v1Pitches),
                division: division,
                isDrumTrack: true,
                maxDots: maxDots,
            ))
        }
        return result
    }

    private static func pitchesInVoice(
        _ voiceIdx: Int, in measure: ImportMeasure,
    ) -> Set<Int> {
        var pitches: Set<Int> = []
        for ev in measure.events {
            if case let .noteOn(_, p, v) = ev.event, v > 0,
               gmDrumVoiceIndex(for: p) == voiceIdx
            {
                pitches.insert(p)
            }
        }
        return pitches
    }

    private static func filterMeasure(
        _ measure: ImportMeasure, keepingPitches pitches: Set<Int>,
    ) -> ImportMeasure {
        var copy = measure
        copy.events = measure.events.filter { ev in
            switch ev.event {
            case let .noteOn(_, p, _), let .noteOff(_, p, _):
                return pitches.contains(p)
            default:
                return true // keep meta / endOfTrack
            }
        }
        copy.carryIns = measure.carryIns.filter { pitches.contains($0.pitch) }
        copy.carryOuts = measure.carryOuts.filter { pitches.contains($0.pitch) }
        return copy
    }
}
