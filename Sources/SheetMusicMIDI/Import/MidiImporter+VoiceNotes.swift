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
    /// After snapping, drops any zero-length notes (where on == off).
    static func snapVoiceNotesToGrid(
        _ notes: [VoiceNote],
        quantized: QuantizedMeasure,
    ) -> [VoiceNote] {
        notes.map { n in
            VoiceNote(
                onTick: snapToQuantizedGrid(
                    n.onTick,
                    assignments: quantized.assignments,
                    fallbackGrid: quantized.binaryGrid,
                ),
                offTick: snapToQuantizedGrid(
                    n.offTick,
                    assignments: quantized.assignments,
                    fallbackGrid: quantized.binaryGrid,
                ),
                pitch: n.pitch,
                velocity: n.velocity,
                startsTied: n.startsTied,
                endsTied: n.endsTied,
            )
        }
        .filter { $0.onTick < $0.offTick }
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
