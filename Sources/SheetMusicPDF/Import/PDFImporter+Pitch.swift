import CoreGraphics
import Foundation
import SheetMusicCore

extension PDFImporter {
    /// Result of pitch decoding for a single notehead in a measure.
    struct DecodedPitch: Equatable {
        var midi: Int
        var tpc: Int
        var noteheadX: CGFloat
        var noteheadY: CGFloat
        var glyph: ClassifiedGlyph

        static func == (lhs: DecodedPitch, rhs: DecodedPitch) -> Bool {
            lhs.midi == rhs.midi && lhs.tpc == rhs.tpc
                && lhs.noteheadX == rhs.noteheadX
                && lhs.noteheadY == rhs.noteheadY
                && lhs.glyph.raw == rhs.glyph.raw
        }
    }

    /// Decode notehead pitches for one measure under the given clef +
    /// key. Local accidentals reset at every measure boundary, so this
    /// function carries no cross-measure state.
    static func decodePitches(
        measure: ImportMeasure,
        activeClef: Clef,
        activeKey: KeySignature,
    ) -> [DecodedPitch] {
        guard !measure.staffYLines.isEmpty,
              let anchor = staffAnchor(clef: activeClef, yLines: measure.staffYLines)
        else { return [] }
        let sorted = measure.glyphs.sorted { $0.raw.origin.x < $1.raw.origin.x }
        let locals = pairAccidentals(sorted: sorted, anchor: anchor)
        var out: [DecodedPitch] = []
        for g in sorted where isNotehead(g.semantic) {
            let key = pitchKey(noteheadY: g.raw.origin.y, anchor: anchor)
            let alteration = locals[key]
                ?? keyAlteration(step: key.diatonicStep, key: activeKey)
            let midi = midiPitch(
                step: key.diatonicStep, octave: key.octave, alteration: alteration,
            )
            out.append(DecodedPitch(
                midi: midi,
                tpc: tonalPitchClass(step: key.diatonicStep, alteration: alteration),
                noteheadX: g.raw.origin.x,
                noteheadY: g.raw.origin.y,
                glyph: g,
            ))
        }
        return out
    }
}

// MARK: - Internal helpers

extension PDFImporter {
    /// Anchor for y → (diatonicStep, octave) conversion. `bottomStep`
    /// is the diatonic ordinal (C=0..B=6) of `bottomY`; `bottomOctave`
    /// is its scientific octave.
    struct StaffAnchor {
        var bottomY: CGFloat
        var lineSpacing: CGFloat
        var bottomStep: Int
        var bottomOctave: Int
    }

    struct PitchKey: Hashable {
        let diatonicStep: Int // 0=C..6=B
        let octave: Int
    }

    static func staffAnchor(clef: Clef, yLines: [CGFloat]) -> StaffAnchor? {
        guard let bottomY = yLines.first, let topY = yLines.last,
              yLines.count >= 2, topY > bottomY
        else { return nil }
        let lineSpacing = (topY - bottomY) / CGFloat(yLines.count - 1)
        switch clef.concertClefType {
        case "G": // treble: bottom line = E4
            return StaffAnchor(
                bottomY: bottomY,
                lineSpacing: lineSpacing,
                bottomStep: 2,
                bottomOctave: 4,
            )
        case "F": // bass: bottom line = G2
            return StaffAnchor(
                bottomY: bottomY,
                lineSpacing: lineSpacing,
                bottomStep: 4,
                bottomOctave: 2,
            )
        case "C": // alto C clef: bottom line = F3
            return StaffAnchor(
                bottomY: bottomY,
                lineSpacing: lineSpacing,
                bottomStep: 3,
                bottomOctave: 3,
            )
        case "PERCUSSION":
            return nil
        default:
            return StaffAnchor(
                bottomY: bottomY,
                lineSpacing: lineSpacing,
                bottomStep: 2,
                bottomOctave: 4,
            )
        }
    }

    static func isNotehead(_ s: SMuFLSemantic) -> Bool {
        switch s {
        case .noteheadBlack, .noteheadHalf,
             .noteheadWhole, .noteheadDoubleWhole:
            true
        default:
            false
        }
    }

    /// Map an accidental glyph's semantic to a chromatic alteration.
    /// Returns nil for non-accidental glyphs.
    static func accidentalAlteration(_ s: SMuFLSemantic) -> Int? {
        switch s {
        case .accidentalSharp: 1
        case .accidentalFlat: -1
        case .accidentalNatural: 0
        case .accidentalDoubleSharp: 2
        case .accidentalDoubleFlat: -2
        default: nil
        }
    }

    /// Walk the x-sorted glyph list, pair each accidental with the
    /// next notehead at the same y (within ~2pt), and record local
    /// alterations keyed by (diatonicStep, octave).
    static func pairAccidentals(
        sorted: [ClassifiedGlyph], anchor: StaffAnchor,
    ) -> [PitchKey: Int] {
        var locals: [PitchKey: Int] = [:]
        for (i, g) in sorted.enumerated() {
            guard let alt = accidentalAlteration(g.semantic) else { continue }
            for j in (i + 1) ..< sorted.count {
                let nh = sorted[j]
                if isNotehead(nh.semantic),
                   abs(nh.raw.origin.y - g.raw.origin.y) < 2
                {
                    let key = pitchKey(noteheadY: nh.raw.origin.y, anchor: anchor)
                    locals[key] = alt
                    break
                }
            }
        }
        return locals
    }

    /// y-coordinate → diatonic step + octave. yLines ascending → up
    /// the staff visually → up in pitch.
    static func pitchKey(noteheadY: CGFloat, anchor: StaffAnchor) -> PitchKey {
        // 1 diatonic step = lineSpacing / 2 (a step covers half the
        // distance between adjacent staff lines).
        let halfStep = anchor.lineSpacing / 2
        let raw = (noteheadY - anchor.bottomY) / halfStep
        let stepsAbove = Int(raw.rounded())
        let absStep = anchor.bottomStep + stepsAbove
        let step = ((absStep % 7) + 7) % 7
        // Floor-divide for negative values: octave decreases properly
        // for ledger lines below the staff.
        let octaveDelta: Int
        if absStep >= 0 {
            octaveDelta = absStep / 7
        } else {
            octaveDelta = -((-absStep + 6) / 7)
        }
        return PitchKey(diatonicStep: step, octave: anchor.bottomOctave + octaveDelta)
    }

    /// Apply a key signature default to a diatonic step. Positive
    /// `concertKey` = sharps in the order F,C,G,D,A,E,B; negative =
    /// flats in the reverse order B,E,A,D,G,C,F.
    static func keyAlteration(step: Int, key: KeySignature) -> Int {
        let sharpOrder = [3, 0, 4, 1, 5, 2, 6] // F,C,G,D,A,E,B
        let flatOrder = [6, 2, 5, 1, 4, 0, 3] // B,E,A,D,G,C,F
        if key.concertKey > 0 {
            let n = min(key.concertKey, sharpOrder.count)
            return sharpOrder.prefix(n).contains(step) ? 1 : 0
        }
        if key.concertKey < 0 {
            let n = min(-key.concertKey, flatOrder.count)
            return flatOrder.prefix(n).contains(step) ? -1 : 0
        }
        return 0
    }

    /// MIDI 60 = C4. Step → semitone offset C=0, D=2, E=4, F=5, G=7,
    /// A=9, B=11. Octave is scientific-pitch-notation.
    static func midiPitch(step: Int, octave: Int, alteration: Int) -> Int {
        let semitones = [0, 2, 4, 5, 7, 9, 11]
        return 12 * (octave + 1) + semitones[step] + alteration
    }

    /// MuseScore tonal-pitch-class number on the line of fifths.
    /// tpc = stepOnFifths + alteration*7 + 14.
    /// Step on line of fifths: C=0, D=2, E=4, F=-1, G=1, A=3, B=5.
    static func tonalPitchClass(step: Int, alteration: Int) -> Int {
        let fifths = [0, 2, 4, -1, 1, 3, 5]
        return fifths[step] + alteration * 7 + 14
    }
}
