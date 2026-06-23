import Foundation
import SheetMusicCore

// TIE-PITCH PROPAGATION. A conservative, monotonic post-pass that fixes a
// tied-back note whose pitch was decoded WITHOUT the accidental that the
// tie carries forward from its source note.
//
// Why this is needed: pitch is decoded per measure, with measure-local
// accidental semantics (PDFImporter+Pitch). A note tied across a barline
// (or from an earlier note within the bar) inherits its predecessor's
// pitch — including any accidental — but MuseScore does NOT redraw the
// accidental on the continuation note, so the per-measure decoder, seeing
// no accidental and no key-signature alteration on that step, reads the
// natural pitch. Example: ギブス p0 m10 n0 is tied back from m9's E♭4
// (63); with no flat glyph in m10 the decoder read E♮4 (64).
//
// The tie geometry itself is already recovered correctly (the tie-forward
// / tie-back flags on A and B agree), so the fix is purely to make a
// tied-back note's pitch equal the pitch of the note it is tied FROM — the
// musical invariant that defines a tie. Two consecutive notes of a tie
// chain are adjacent in their voice's note sequence, so walking each
// voice's notes in order and copying the source pitch onto each tied-back
// continuation is exact.
//
// Monotonicity: a tied-back note whose decoded pitch ALREADY equals its
// source's (the common case — the accidental was visible, or none was
// needed) is left byte-identical. Only a genuine mismatch is repaired, and
// only by adopting the source pitch, so no correctly-decoded pitch can
// regress.

extension PDFImporter {
    /// Propagate pitch (and tpc) along tie chains across every staff of the
    /// assembled parts. See file header for the rationale and invariants.
    static func propagateTiePitches(parts: inout [Part]) {
        for pi in parts.indices {
            for si in parts[pi].staves.indices {
                propagateTiePitches(staff: &parts[pi].staves[si])
            }
        }
    }

    /// Propagate tie pitches within one staff, independently per voice
    /// index. A tie lives in a single voice, so the continuation note is the
    /// next note in that voice's cross-measure sequence.
    private static func propagateTiePitches(staff: inout SheetMusicCore.Staff) {
        // Maximum voice count across the staff's measures.
        let voiceCount = staff.measures.map(\.voices.count).max() ?? 0
        for vi in 0 ..< voiceCount {
            propagateTiePitches(staff: &staff, voiceIndex: vi)
        }
    }

    /// Address of one note-bearing chord within a staff: (measure, voice,
    /// element). Used to mutate the chord in place after walking the
    /// sequence.
    private struct ChordAddress {
        var measure: Int
        var voice: Int
        var element: Int
    }

    private static func propagateTiePitches(
        staff: inout SheetMusicCore.Staff, voiceIndex vi: Int,
    ) {
        // Collect, in temporal order, the addresses of note-bearing chords
        // in this voice across all measures.
        var sequence: [ChordAddress] = []
        for (mi, measure) in staff.measures.enumerated() {
            guard vi < measure.voices.count else { continue }
            for (ei, el) in measure.voices[vi].elements.enumerated() {
                if case let .chord(c) = el, !c.notes.isEmpty {
                    sequence.append(ChordAddress(measure: mi, voice: vi, element: ei))
                }
            }
        }
        guard sequence.count >= 2 else { return }

        // Walk consecutive chords; when the earlier carries a tie-forward
        // note and the later a tie-back note, copy the source pitch onto the
        // continuation. Only single-note chords are propagated — a tie on a
        // multi-note chord needs the per-note pairing the score model does
        // not retain after assembly, so those are left untouched (this
        // corpus has only single-note chords).
        for k in 0 ..< (sequence.count - 1) {
            let src = sequence[k]
            let dst = sequence[k + 1]
            guard let source = leadTiedForwardNote(staff: staff, at: src),
                  hasTiedBackLeadNote(staff: staff, at: dst)
            else { continue }
            adoptPitch(staff: &staff, at: dst, from: source)
        }
    }

    /// The lead note of the chord at `addr` IF it is a single-note chord
    /// carrying a forward tie; otherwise nil.
    private static func leadTiedForwardNote(
        staff: SheetMusicCore.Staff, at addr: ChordAddress,
    ) -> Note? {
        guard case let .chord(c) = staff.measures[addr.measure]
            .voices[addr.voice].elements[addr.element],
            c.notes.count == 1
        else { return nil }
        let note = c.notes[c.notes.startIndex]
        return note.tieForward != nil ? note : nil
    }

    /// Whether the chord at `addr` is a single-note chord whose lead note
    /// carries a back tie.
    private static func hasTiedBackLeadNote(
        staff: SheetMusicCore.Staff, at addr: ChordAddress,
    ) -> Bool {
        guard case let .chord(c) = staff.measures[addr.measure]
            .voices[addr.voice].elements[addr.element],
            c.notes.count == 1
        else { return false }
        return c.notes[c.notes.startIndex].tieBack != nil
    }

    /// Adopt `source`'s pitch + tpc onto the lead note of the chord at
    /// `addr`, but ONLY when they differ (preserves byte-identity for the
    /// already-correct common case — the monotonicity guarantee).
    private static func adoptPitch(
        staff: inout SheetMusicCore.Staff,
        at addr: ChordAddress,
        from source: Note,
    ) {
        guard case var .chord(c) = staff.measures[addr.measure]
            .voices[addr.voice].elements[addr.element],
            c.notes.count == 1
        else { return }
        let idx = c.notes.startIndex
        let current = c.notes[idx]
        guard current.pitch != source.pitch || current.tpc != source.tpc else { return }
        c.notes.updateNote(at: idx) { note in
            note.pitch = source.pitch
            note.tpc = source.tpc
        }
        staff.measures[addr.measure].voices[addr.voice].elements[addr.element] = .chord(c)
    }
}
