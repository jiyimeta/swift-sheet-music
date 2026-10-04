import SheetMusicCore
import SheetMusicFoundation

// MARK: - VoiceNote

/// Minimal note span used internally by the voicing pass.
struct VoiceNote {
    var onTick: Int
    var offTick: Int
    var pitch: Int
    /// Velocity of the originating noteOn, preserved onto the emitted
    /// `Note.userVelocity`. See `MidiImporter.buildNote`.
    var velocity = 0
    /// True when the note is a continuation from a prior bar (carryIn).
    var startsTied = false
    /// True when the note continues into the next bar (carryOut).
    var endsTied = false
}

// MARK: - Gathering

extension MidiImporter {
    /// Collect `(onTick, offTick, pitch, velocity)` spans from the
    /// measure's event stream.
    static func collectNotes(from measure: ImportMeasure) -> [VoiceNote] {
        var open: [(channel: Int, pitch: Int, onTick: Int, velocity: Int)] = []
        var notes: [VoiceNote] = []
        for ev in measure.events {
            switch ev.event {
            case let .noteOn(c, p, v) where v > 0:
                open.append((c, p, ev.tick, v))
            case let .noteOn(c, p, _),
                 let .noteOff(c, p, _):
                if let i = open.firstIndex(where: { $0.channel == c && $0.pitch == p }) {
                    let n = open.remove(at: i)
                    notes.append(VoiceNote(
                        onTick: n.onTick, offTick: ev.tick,
                        pitch: p, velocity: n.velocity,
                    ))
                }
            default: break
            }
        }
        for n in open {
            notes.append(VoiceNote(
                onTick: n.onTick, offTick: measure.endTick,
                pitch: n.pitch, velocity: n.velocity,
            ))
        }
        return notes
    }

    /// Snap each VoiceNote's on/off ticks to the same grid the
    /// quantizer chose (binary or tuplet) so chord gaps land on
    /// standard note values. Without this voice() would walk raw
    /// event ticks, and any drift from the grid (typical in
    /// DAW-exported MIDI) would produce `.fraction` durations that
    /// downstream layout can't render as notation.
    ///
    /// A played note shorter than half a grid step snaps shut — both ends land on the same grid point — and keeps
    /// one step instead of vanishing: MuseScore's `findQuantizedNoteOffTime` moves an off time that quantizes onto
    /// its on time one quantum later. Sequencers write every drum hit as a fixed blip (1/48 of a beat is common),
    /// so dropping these emptied whole drum parts. What still drops: a note that was zero-length to begin with, a
    /// continuation from the previous bar that ends at this barline's grid point (release jitter, not a note), and
    /// a note whose onset snaps onto the barline that ends this measure.
    static func snapVoiceNotesToGrid(
        _ notes: [VoiceNote],
        quantized: QuantizedMeasure,
        measureEndTick: Int,
    ) -> [VoiceNote] {
        notes.compactMap { n in
            let onTick = snapToQuantizedGrid(
                n.onTick, assignments: quantized.assignments, fallbackGrid: quantized.binaryGrid,
            )
            var offTick = snapToQuantizedGrid(
                n.offTick, assignments: quantized.assignments, fallbackGrid: quantized.binaryGrid,
            )
            if offTick <= onTick {
                guard n.offTick > n.onTick, !n.startsTied, onTick < measureEndTick else { return nil }
                offTick = min(onTick + gridStep(at: onTick, in: quantized), measureEndTick)
            }
            return VoiceNote(
                onTick: onTick,
                offTick: offTick,
                pitch: n.pitch,
                velocity: n.velocity,
                startsTied: n.startsTied,
                endsTied: n.endsTied,
            )
        }
    }

    /// The step of the grid that owns `tick` — its assignment's (binary or tuplet), else the binary fallback.
    private static func gridStep(at tick: Int, in quantized: QuantizedMeasure) -> Int {
        let owning = quantized.assignments.first { $0.range.contains(tick) }
        return max(owning?.grid ?? quantized.binaryGrid, 1)
    }

    /// Lengthen each drum note to the next onset in its voice, the end of the beat its release falls in, or the
    /// barline — whichever comes first — and never past a tuplet edge.
    ///
    /// A drum's duration means nothing to a GM kit, so sequencers write whatever is convenient, and notating the
    /// written length verbatim buries the rhythm in rests: an eighth-note hi-hat written as blips reads as sixteenth
    /// plus sixteenth rest. MuseScore's `Simplify::minimizeNumberOfRests` → `lengthenNote` does exactly this for
    /// drum tracks (beat via `Meter::beatLength`, which counts a compound meter's dotted beat). Only lengthens, and
    /// leaves notes tied across a barline alone.
    static func lengthenedDrumNotes(
        _ notes: [VoiceNote],
        quantized: QuantizedMeasure,
        measure: ImportMeasure,
        division: Int,
    ) -> [VoiceNote] {
        let onsets = Set(notes.map(\.onTick)).sorted()
        let beat = beatTicks(of: measure.timeSignature, division: division)
        return notes.map { note in
            guard !note.startsTied, !note.endsTied, beat > 0 else { return note }
            let offsetInBar = note.offTick - measure.startTick
            var end = min(measure.endTick, measure.startTick + (offsetInBar + beat - 1) / beat * beat)
            if let next = onsets.first(where: { $0 > note.onTick }) { end = min(end, next) }
            for range in quantized.tupletTickRanges {
                if range.contains(note.onTick) { end = min(end, range.upperBound) }
                if range.lowerBound > note.onTick { end = min(end, range.lowerBound) }
            }
            guard end > note.offTick else { return note }
            var lengthened = note
            lengthened.offTick = end
            return lengthened
        }
    }

    /// MuseScore's `Meter::beatLength` (`importmidi_meter.cpp`), ported as written: a duple bar (2 or 6 on top)
    /// beats in halves, a triple one (3 or 9) in thirds, a quadruple one (a multiple of 4) in quarters, a complex
    /// one (5 or 7) in its numerator's units, anything else in quarters. So 6/8 beats in dotted quarters and 4/4
    /// in quarters.
    private static func beatTicks(of signature: TimeSignature, division: Int) -> Int {
        let numerator = signature.numerator
        let barTicks = numerator * division * 4 / max(signature.denominator, 1)
        let beatsPerBar = switch numerator {
        case 2, 6: 2
        case 3, 9: 3
        case 5, 7: numerator
        default: 4
        }
        return barTicks / beatsPerBar
    }

    /// Synthesise a `startsTied` VoiceNote at the measure head for each carryIn.
    static func mergeCarryIns(into notes: inout [VoiceNote], measure: ImportMeasure) {
        for carried in measure.carryIns {
            notes.append(VoiceNote(
                onTick: measure.startTick,
                offTick: min(carried.noteOffTick, measure.endTick),
                pitch: carried.pitch,
                velocity: carried.velocity,
                startsTied: true,
            ))
        }
    }

    /// Mark the matching VoiceNote `endsTied` for each carryOut, synthesising
    /// one if the noteOn did not fall within this measure.
    static func mergeCarryOuts(into notes: inout [VoiceNote], measure: ImportMeasure) {
        for carried in measure.carryOuts {
            let onTick = max(carried.noteOnTick, measure.startTick)
            if let idx = notes.firstIndex(where: { $0.pitch == carried.pitch && $0.onTick == onTick }) {
                notes[idx].endsTied = true
                notes[idx].offTick = measure.endTick
            } else {
                notes.append(VoiceNote(
                    onTick: onTick,
                    offTick: measure.endTick,
                    pitch: carried.pitch,
                    velocity: carried.velocity,
                    endsTied: true,
                ))
            }
        }
    }
}
