#if canImport(CoreGraphics)
    import CoreGraphics
#endif
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
        /// The accidental glyph paired directly to THIS notehead (its own
        /// written accidental), or nil when the note carries none. Set only
        /// when an accidental at this note's pitch sits immediately to its
        /// left — not one inherited via measure-local carry from an earlier
        /// same-pitch note. Consumed by the assembled `Note.accidental`, which
        /// the tie-pitch pass reads as "this note has its own accidental, so a
        /// tie must not overwrite its pitch" (see PDFImporter+TiePitch).
        var accidental: Accidental?

        static func == (lhs: DecodedPitch, rhs: DecodedPitch) -> Bool {
            lhs.midi == rhs.midi && lhs.tpc == rhs.tpc
                && lhs.noteheadX == rhs.noteheadX
                && lhs.noteheadY == rhs.noteheadY
                && lhs.glyph.geometry == rhs.glyph.geometry
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
        // Percussion staves have no pitched meaning. Map each notehead's
        // staff position + notehead type to a GM drumset MIDI number and
        // skip the accidental / key machinery entirely. This keeps drum
        // noteheads alive as notes (the round-note path would drop them via
        // the same anchor, but the pitches would be diatonic nonsense; the
        // drumset mapping is at least conventionally meaningful, and the
        // harness reports percussion staves separately from pitched ones).
        if activeClef.concertClefType == "PERCUSSION" {
            return decodePercussion(measure: measure, anchor: anchor)
        }
        let sorted = measure.glyphs.sorted { $0.geometry.origin.x < $1.geometry.origin.x }
        let placed = pairAccidentalsPositional(sorted: sorted, anchor: anchor)
        // Running measure-local accidental state: an accidental applies to
        // its own note and all SUBSEQUENT same-pitch notes in the measure,
        // never to PRECEDING ones. (A position-agnostic dict flatted the
        // whole bar — e.g. a B♭ on beat 3 wrongly dragged a B♮ on beat 1 to
        // B♭, a recurring A=71/B=70 error on this score.)
        var activeLocals: [PitchKey: Int] = [:]
        var nextAcc = 0
        var out: [DecodedPitch] = []
        for g in sorted where isNotehead(g.semantic) {
            let key = pitchKey(noteheadY: g.geometry.origin.y, anchor: anchor)
            // Promote every accidental whose x is at or before this
            // notehead into the running state before resolving it. An
            // accidental at THIS note's pitch promoted in this batch (i.e.
            // sitting between the previous notehead and this one) is this
            // note's OWN written accidental — record its alteration so the
            // assembled note can carry it.
            var ownAlteration: Int?
            while nextAcc < placed.count, placed[nextAcc].x <= g.geometry.origin.x + 0.5 {
                if placed[nextAcc].key == key { ownAlteration = placed[nextAcc].alt }
                activeLocals[placed[nextAcc].key] = placed[nextAcc].alt
                nextAcc += 1
            }
            let keyAlt = keyAlteration(step: key.diatonicStep, key: activeKey)
            let alteration = activeLocals[key] ?? keyAlt
            let midi = midiPitch(
                step: key.diatonicStep, octave: key.octave, alteration: alteration,
            )
            // A note's own written accidental is pitch EVIDENCE only when it
            // DEVIATES from the key's default for this step. An accidental that
            // merely restates the key does not — and a key-signature accidental
            // geometrically mis-paired to a same-position note (its 3rd flat
            // hugging a whole note at that line: 群青 p1 m80) always matches the
            // key alteration, so this test excludes every such mis-pairing while
            // still catching a real deviation (m84's F♯♯ = +2 vs key +1). Only a
            // deviating accidental is recorded, so the tie guard fires only on
            // genuine evidence.
            let ownAccidental = ownAlteration.flatMap { alt in
                alt != keyAlt ? writtenAccidental(forAlteration: alt) : nil
            }
            out.append(DecodedPitch(
                midi: midi,
                tpc: tonalPitchClass(step: key.diatonicStep, alteration: alteration),
                noteheadX: g.geometry.origin.x,
                noteheadY: g.geometry.origin.y,
                glyph: g,
                accidental: ownAccidental,
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
        // Bottom-staff-line (diatonicStep, scientific octave) per clef.
        // Octave clefs share their parent's step and shift the octave: G
        // family = E (step 2), F family = G (step 4). PERCUSSION has no
        // pitched meaning but gets a treble-like anchor so `decodePitches`
        // still runs and its noteheads SURVIVE as notes (the percussion
        // branch remaps them to GM drumset numbers via `percussionMidi`).
        let (step, octave) = clefBottomLine(clef.concertClefType)
        return StaffAnchor(
            bottomY: bottomY,
            lineSpacing: lineSpacing,
            bottomStep: step,
            bottomOctave: octave,
        )
    }

    /// Diatonic step (C=0..B=6) and scientific octave of a staff's bottom
    /// line for a given `concertClefType`. Unknown clefs fall back to
    /// treble (E4), matching the prior default branch.
    private static func clefBottomLine(_ type: String) -> (step: Int, octave: Int) {
        switch type {
        case "G": (2, 4) // treble: E4
        case "G8vb": (2, 3) // treble 8vb (vocal tenor): E3
        case "G8va": (2, 5) // treble 8va: E5
        case "G15ma": (2, 6) // treble 15ma: E6
        case "G15mb": (2, 2) // treble 15mb: E2
        case "F": (4, 2) // bass: G2
        case "F8va": (4, 3) // bass 8va: G3
        case "F8vb": (4, 1) // bass 8vb: G1
        case "F15ma": (4, 4) // bass 15ma: G4
        case "F15mb": (4, 0) // bass 15mb: G0
        case "C": (3, 3) // alto C: F3
        default: (2, 4) // PERCUSSION + unknown → treble E4
        }
    }

    static func isNotehead(_ s: SMuFLSemantic) -> Bool {
        switch s {
        case .noteheadBlack, .noteheadHalf,
             .noteheadWhole, .noteheadDoubleWhole,
             .noteheadXBlack, .noteheadXHalf, .noteheadXWhole:
            true
        default:
            false
        }
    }

    /// True for the X-style noteheads (cymbals / hi-hat on a drum staff).
    static func isXNotehead(_ s: SMuFLSemantic) -> Bool {
        switch s {
        case .noteheadXBlack, .noteheadXHalf, .noteheadXWhole: true
        default: false
        }
    }

    /// True for a FILLED notehead (black / X-black), drawn for a quarter or
    /// shorter value. A half / whole / double-whole is HOLLOW. Used by the
    /// reconciliation pass to reject a geometrically-impossible re-value of a
    /// filled note to a half-or-longer duration.
    static func isFilledNotehead(_ s: SMuFLSemantic) -> Bool {
        switch s {
        case .noteheadBlack, .noteheadXBlack: true
        default: false
        }
    }

    /// True for a combined flag glyph (8th…64th, up or down). A flag carries
    /// only a note's duration subdivision — never pitch — so it is safe to
    /// capture from a wider vertical band than pitched glyphs.
    static func isFlag(_ s: SMuFLSemantic) -> Bool {
        switch s {
        case .flag8thUp, .flag8thDown, .flag16thUp, .flag16thDown,
             .flag32ndUp, .flag32ndDown, .flag64thUp, .flag64thDown:
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

    /// Inverse of `accidentalAlteration` over the five alterations
    /// `pairAccidentalsPositional` can produce (±1, ±2, 0). Used to stamp a
    /// decoded note's own written accidental onto the assembled `Note`.
    static func writtenAccidental(forAlteration alt: Int) -> Accidental? {
        switch alt {
        case 1: .sharp
        case -1: .flat
        case 0: .natural
        case 2: .doubleSharp
        case -2: .doubleFlat
        default: nil
        }
    }

    /// One accidental resolved to the pitch it modifies, positioned at the
    /// accidental glyph's x so the caller can apply standard measure-local
    /// semantics (effective from this x rightward only).
    struct PlacedAccidental {
        var x: CGFloat
        var key: PitchKey
        var alt: Int
    }

    /// Walk the x-sorted glyph list and resolve each accidental to the
    /// notehead it modifies, returning the alteration positioned at the
    /// accidental's own x (sorted ascending).
    ///
    /// A local accidental sits immediately to the LEFT of its notehead at
    /// essentially the same y (same staff position). Two precision gates
    /// matter on the dense Gibbs vocal staves (half-step ≈ 2pt):
    /// - **x proximity**: the note must be within ~`maxPairDx` to the
    ///   right. Without this an accidental at the bar's left could bind to
    ///   a far-right note that merely shares a staff line, flipping that
    ///   note's alteration spuriously.
    /// - **nearest y**: pick the y-closest qualifying notehead, not just
    ///   the first one within tolerance, so an accidental does not bleed
    ///   onto a neighbor one diatonic step away.
    static func pairAccidentalsPositional(
        sorted: [ClassifiedGlyph], anchor: StaffAnchor,
    ) -> [PlacedAccidental] {
        // Pair within ~3.5 half-steps of x (a local accidental hugs its
        // note; key-sig accidentals are filtered upstream by readKey but
        // could still appear here, and the x gate keeps them from binding
        // to a distant note).
        let maxPairDx = max(anchor.lineSpacing * 3.5, 14)
        let yTol = max(anchor.lineSpacing / 2 * 0.9, 1.5)
        var placed: [PlacedAccidental] = []
        for (i, g) in sorted.enumerated() {
            guard let alt = accidentalAlteration(g.semantic) else { continue }
            var best: (j: Int, dy: CGFloat)?
            for j in (i + 1) ..< sorted.count {
                let nh = sorted[j]
                guard isNotehead(nh.semantic) else { continue }
                let dx = nh.geometry.origin.x - g.geometry.origin.x
                if dx > maxPairDx { break } // x-sorted: nothing closer beyond
                let dy = abs(nh.geometry.origin.y - g.geometry.origin.y)
                guard dy <= yTol else { continue }
                if let current = best {
                    if dy < current.dy { best = (j, dy) }
                } else {
                    best = (j, dy)
                }
            }
            if let best {
                let nh = sorted[best.j]
                let key = pitchKey(noteheadY: nh.geometry.origin.y, anchor: anchor)
                placed.append(PlacedAccidental(x: g.geometry.origin.x, key: key, alt: alt))
            }
        }
        return placed.sorted { $0.x < $1.x }
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
