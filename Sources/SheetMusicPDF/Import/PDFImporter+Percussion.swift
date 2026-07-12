#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
import SheetMusicCore

/// Percussion-staff pitch decoding. A drum staff carries no pitched
/// meaning; each notehead's staff position + head shape maps to a General
/// MIDI drumset key. Split out of PDFImporter+Pitch.swift to keep each
/// file within the length cap.
extension PDFImporter {
    /// Decode a percussion-staff measure: every notehead survives as a
    /// note whose MIDI value comes from the standard GM drumset line/space
    /// convention (see `percussionMidi`). No accidentals / key signatures
    /// apply on a drum staff, so this path is deliberately minimal.
    static func decodePercussion(
        measure: ImportMeasure, anchor: StaffAnchor,
    ) -> [DecodedPitch] {
        let sorted = measure.glyphs.sorted { $0.raw.origin.x < $1.raw.origin.x }
        var out: [DecodedPitch] = []
        for g in sorted where isNotehead(g.semantic) {
            let midi = percussionMidi(
                noteheadY: g.raw.origin.y,
                isX: isXNotehead(g.semantic),
                anchor: anchor,
            )
            out.append(DecodedPitch(
                midi: midi,
                tpc: 22, // neutral TPC (C natural); unused for drum staves
                noteheadX: g.raw.origin.x,
                noteheadY: g.raw.origin.y,
                glyph: g,
            ))
        }
        return out
    }

    /// Map a percussion notehead to a General-MIDI drumset note (channel-10
    /// key number), keyed on its vertical staff position and notehead type.
    ///
    /// Mirrors MuseScore 3's **default drumset** — the `<Drum>` line/head
    /// table MuseScore embeds in every percussion staff's instrument (and
    /// which is what positions the noteheads in the exported PDF). In that
    /// table `line` is measured from the TOP staff line downward (top line
    /// = 0, bottom line = 8); we measure `stepsAbove` from the BOTTOM line
    /// upward, so `stepsAbove = 8 - line`. The achievable signal from a PDF
    /// glyph is (staff position, round-vs-cross notehead) only — several GM
    /// drums can share one `(line, head)` slot, so where a slot is shared we
    /// pick the musically dominant member, verified against the 3-score
    /// percussion-corpus confusion tables (snare 38 @ sa5, closed hat 42 @
    /// sa9, ride 51 @ sa8, etc.).
    static func percussionMidi(
        noteheadY: CGFloat, isX: Bool, anchor: StaffAnchor,
    ) -> Int {
        let halfStep = anchor.lineSpacing / 2
        let stepsAbove = halfStep > 0
            ? Int(((noteheadY - anchor.bottomY) / halfStep).rounded())
            : 0
        if isX {
            // Cross noteheads: hi-hats / cymbals (upper staff & above) +
            // side stick (mid staff) + pedal hi-hat (below staff).
            switch stepsAbove {
            case ...0: return 44 // pedal hi-hat (line 9, below the staff)
            case 1 ... 6: return 37 // side stick (line 3 ≈ sa5)
            case 7: return 46 // open hi-hat (line 1)
            case 8: return 51 // ride cymbal 1 (line 0, top line)
            case 9: return 42 // closed hi-hat (line -1, above top line)
            case 10: return 49 // crash cymbal 1 (line -2)
            default: return 55 // splash / china / crash 2 (line ≤ -3)
            }
        }
        // Round noteheads: kick / snare / toms, low → high staff position.
        switch stepsAbove {
        case ...1: return 36 // bass drum 1 (line 7, bottom space)
        case 2 ... 3: return 43 // floor toms (line 5)
        case 4 ... 5: return 38 // acoustic snare (line 3, 3rd space ~C5)
        case 6: return 45 // low tom (line 2)
        case 7: return 47 // low-mid tom (line 1)
        default: return 50 // high / hi-mid tom (line 0, top line and above)
        }
    }
}
