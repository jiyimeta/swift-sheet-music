import Foundation
import SheetMusicCore

extension MidiImporter {
    /// Produce a `Voice` from a quantized measure plus the original
    /// `ImportMeasure` (which carries the noteOn/noteOff stream
    /// needed to drive sustained-pitch tracking).
    ///
    /// The `quantized` argument carries tuplet ranges (which we
    /// re-attach to the resulting voice). The actual element list
    /// is rebuilt here from the original event stream so we can
    /// generate `tieForward` / `tieBack` markers correctly across
    /// staggered noteOffs.
    static func voice(
        quantized: QuantizedMeasure,
        measure: ImportMeasure,
        division: Int
    ) -> Voice {
        struct VoiceNote { var onTick: Int; var offTick: Int; var pitch: Int }

        // Collect (onTick, offTick, pitch) triples from the measure.
        var open: [(channel: Int, pitch: Int, onTick: Int)] = []
        var notes: [VoiceNote] = []
        for ev in measure.events {
            switch ev.event {
            case let .noteOn(c, p, v) where v > 0:
                open.append((c, p, ev.tick))
            case let .noteOn(c, p, _),
                 let .noteOff(c, p, _):
                if let i = open.firstIndex(where: { $0.channel == c && $0.pitch == p }) {
                    let n = open.remove(at: i)
                    notes.append(VoiceNote(onTick: n.onTick, offTick: ev.tick, pitch: p))
                }
            default: break
            }
        }
        for n in open {
            notes.append(VoiceNote(onTick: n.onTick, offTick: measure.endTick, pitch: n.pitch))
        }

        // Walk grid positions = sorted union of onsets and offsets,
        // bracketed by the measure boundaries.
        let grid = Set(notes.flatMap { [$0.onTick, $0.offTick] })
            .union([measure.startTick, measure.endTick])
            .sorted()

        var elements: [VoiceElement] = []
        var prev = measure.startTick

        for tick in grid where tick > prev {
            let active = notes.filter { $0.onTick <= prev && $0.offTick > prev }
                .map(\.pitch)
            let willContinue = notes.filter { $0.onTick <= prev && $0.offTick > tick }
                .map(\.pitch)
            let comesFromPrior = notes.filter { $0.onTick < prev && $0.offTick > prev }
                .map(\.pitch)

            let duration = nearestDuration(ticks: tick - prev, division: division)
            let coreNotes: [SheetMusicCore.Note] = active.map { pitch in
                var n = SheetMusicCore.Note(pitch: pitch, tpc: 0)
                if comesFromPrior.contains(pitch) { n.tieBack = 1 }
                if willContinue.contains(pitch) { n.tieForward = 1 }
                return n
            }
            elements.append(.chord(Chord(duration: duration, notes: ChordNotes(coreNotes))))
            prev = tick
        }

        return Voice(elements: elements, tuplets: quantized.tuplets)
    }
}
