import CoreGraphics
import Foundation
import SheetMusicCore

// Grace-note detection + attachment for the rhythm pass. MuseScore renders
// grace / cue noteheads through a down-scaled text / current-transformation
// matrix (~70% of the full notehead size) while keeping the `Tf` operand
// uniform — so the `RawGlyph.renderedSize` (the combined-matrix scale,
// captured in PDFImporter+ContentStream+TextShow) is the only signal that
// separates a grace notehead from a full one.
//
// A detected grace is represented exactly the way the mscx reader (Score A)
// does: as a `GraceChord` on the following main chord's `graceNotesBefore`,
// NOT as a `VoiceElement`. Graces therefore consume no voice time, so the
// main-note count and the x-onsets of the notes after them stay aligned.

extension PDFImporter {
    /// Indices into `glyphs` whose notehead renders below `threshold` (a
    /// grace / cue notehead). Empty when `threshold <= 0` (pass disabled).
    static func graceNoteheadIndices(
        glyphs: [ClassifiedGlyph], threshold: CGFloat,
    ) -> Set<Int> {
        guard threshold > 0 else { return [] }
        var out = Set<Int>()
        for (i, g) in glyphs.enumerated()
            where isNotehead(g.semantic)
            && g.raw.renderedSize > 0
            && g.raw.renderedSize < threshold
        {
            out.insert(i)
        }
        return out
    }

    /// Build one `GraceChord` per grace notehead index (acciaccatura — the
    /// only type this score uses; visual duration eighth, MuseScore's
    /// default for a slashed grace), paired with its x for attachment.
    static func buildGraceChords(
        indices: Set<Int>,
        glyphs: [ClassifiedGlyph],
        pitchByGlyph: [RawGlyph: DecodedPitch],
        tieMarks: TieMarks,
    ) -> [(x: CGFloat, grace: GraceChord)] {
        var graces: [(x: CGFloat, grace: GraceChord)] = []
        for i in indices.sorted() {
            guard let dp = pitchByGlyph[glyphs[i].raw] else { continue }
            let g = glyphs[i]
            let id = NoteheadID(g.raw)
            let note = Note(
                pitch: dp.midi,
                tpc: dp.tpc,
                tieForward: tieMarks.forward.contains(id) ? 1 : nil,
                tieBack: tieMarks.back.contains(id) ? 1 : nil,
            )
            let grace = GraceChord(
                graceType: .acciaccatura,
                duration: .eighth,
                notes: ChordNotes([note]),
            )
            graces.append((x: g.raw.origin.x, grace: grace))
        }
        return graces
    }

    /// Attach each grace chord to the nearest main chord at or to the RIGHT
    /// of its x (MuseScore writes a `graceNotesBefore` immediately left of
    /// its parent). If none follows (grace at bar end), attach to the last
    /// chord. Rests are skipped as parents.
    static func attachGraces(
        _ graces: [(x: CGFloat, grace: GraceChord)],
        to elements: [RhythmElement],
    ) -> [RhythmElement] {
        guard !graces.isEmpty else { return elements }
        var out = elements
        for (gx, grace) in graces {
            // Nearest note-bearing chord whose x >= grace x; else the last.
            var target: Int?
            for (idx, el) in out.enumerated()
                where !el.isRest && el.x >= gx - 0.5
            {
                target = idx
                break
            }
            if target == nil {
                target = out.lastIndex { !$0.isRest }
            }
            guard let t = target else { continue }
            out[t].chord.graceNotesBefore.append(grace)
        }
        return out
    }
}
