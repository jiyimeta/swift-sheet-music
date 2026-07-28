import Foundation
import SheetMusicCore

// MEASURE-REST NORMALIZATION — the one rest reading the geometry rhythm
// decode cannot make on its own, run as the first step of each voice group
// in the metric-sum reconciliation pass (PDFImporter+RhythmReconcile).
// Split out of that file to keep each under the SwiftLint length cap.
//
// MuseScore engraves a voice's FULL-MEASURE rest with the whole-rest glyph
// (`restWhole`, U+E4E3) in EVERY time signature — a 2/4 empty bar and a 4/4
// empty bar draw the identical glyph at the identical staff position. Only
// the bar length tells them apart, and the geometry layer reads glyphs one
// at a time without it.

extension PDFImporter {
    /// Re-read a voice whose ENTIRE content is a single whole rest as a
    /// MEASURE rest (`NoteDuration.measure`), returning whether it fired.
    ///
    /// Taking the glyph at face value (`.whole` = 1/1 of a whole note) is
    /// right only in 4/4; in any shorter bar the voice over-fills. The
    /// single-note repair can't correct it either — rests are never
    /// re-valued — so such a bar simply kept 4/4 worth of time
    /// (`Now_is_the_time.pdf` m3: a 2/4 bar imported as 1920 ticks instead of
    /// 960, so the measure played and laid out as common time).
    ///
    /// `.measure` — rather than `.fraction(barLength)` — is deliberate: it is
    /// how MuseScore itself spells the marker (`<durationType>measure</…>`),
    /// so a PDF-imported empty bar is byte-identical to the mscz ground
    /// truth, it resolves against the measure's ACTUAL length (a pickup bar's
    /// `<Measure len=…>`, not just the nominal signature), and it is the
    /// value `LayoutEngine+Placement` keys on to center the rest in the bar.
    ///
    /// Guarded on the rest being the voice's ONLY element: a whole rest that
    /// shares its bar with other content (a 6/4 bar written whole + half) is
    /// a genuine whole rest and keeps its typed duration. A lone rest of any
    /// SHORTER value is left alone too — that is an under-full voice for the
    /// repair pass to report, not the measure-rest convention.
    static func normalizeMeasureRest(
        indices: [Int], elements: inout [RhythmElement],
    ) -> Bool {
        guard indices.count == 1, let i = indices.first,
              elements[i].isRest,
              elements[i].chord.duration == .whole
        else { return false }
        elements[i].chord.duration = .measure
        return true
    }
}
