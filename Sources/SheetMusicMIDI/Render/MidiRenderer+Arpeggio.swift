import Foundation
import SheetMusicCore

extension MidiRenderer {
    /// Per-note (on-tick, off-tick) offsets for an N-note arpeggio, both
    /// expressed as ticks-from-chord-start.
    /// Mirrors MuseScore's `CompatMidiRender::renderArpeggio` formula:
    ///   l = 64, shrunk by 2/3 until `l * notes ≤ chordTicks`
    ///   ot = (l * j * 1000) / chordTicks * tempoRatio * stretch, clamped to ≤1000
    ///   onOffset(j)  = ot * chordTicks / 1000
    ///   offOffset(j) = onOffset(j) + (1000 − ot) * chordTicks / 1000 − 1
    /// `tempoRatio` = current tempo / DEFAULT_TEMPO (2.0 bps = 120 BPM).
    static func arpeggioNoteEvents(
        noteCount: Int,
        chordTicks: Int,
        stretch: Double,
        tempoBps: Double
    ) -> [(onOffset: Int, offOffset: Int)] {
        guard noteCount > 0, chordTicks > 0 else { return [] }
        var l = 64
        while l > 0 && l * noteCount > chordTicks {
            l = (2 * l) / 3
        }
        let tempoRatio = tempoBps / 2.0
        var result: [(Int, Int)] = []
        result.reserveCapacity(noteCount)
        for j in 0 ..< noteCount {
            // Match C++ operator precedence: integer division first, then ×Double.
            let intPart = (l * j * 1000) / chordTicks
            let raw = Double(intPart) * tempoRatio * stretch
            let ot = Int(min(1000.0, raw))
            let onOffset = ot * chordTicks / 1000
            let lengthTicks = (1000 - ot) * chordTicks / 1000
            let offOffset = onOffset + lengthTicks - 1
            result.append((onOffset, offOffset))
        }
        return result
    }
}
