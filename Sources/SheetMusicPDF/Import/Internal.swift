import CoreGraphics
import Foundation
import PDFKit
import SheetMusicCore

// Internal types shared across `PDFImporter+<Stage>` extensions. All
// declarations here are deliberately `internal` (default visibility) —
// only the `PDFImporter` façade and `PDFImportOptions` are public.

/// Raw glyph captured from one Tj / TJ operator. Position is the
/// text origin in PDF page coordinates (origin = bottom-left).
struct RawGlyph: Hashable {
    var codepoint: UInt32 // Unicode scalar (often a SMuFL PUA codepoint)
    var fontName: String // PostScript name as reported by PDFKit
    var fontSize: CGFloat // points (raw Tf operand — uniform per font)
    var origin: CGPoint
    var advance: CGFloat // horizontal advance to the next glyph in points
    var pageIndex: Int
    /// Effective page-space rendered size = `fontSize × sqrt(det(textMatrix ×
    /// ctm))`. MuseScore renders grace / cue noteheads by scaling the text
    /// or current-transformation matrix rather than changing the `Tf`
    /// operand (which stays 100 across the whole score), so this is the
    /// only signal distinguishing a small grace notehead from a full one.
    var renderedSize: CGFloat = 0
}

/// One straight or rectangular path segment captured from m/l/re
/// content-stream operators. Used by staff-line and barline detection.
///
/// `.beam` is a filled near-horizontal parallelogram captured from a
/// `m l l l (h) f` quad — MuseScore renders each beam line that way.
/// Its `rect` is the page-space bounding box (so x-extent spans the
/// stems it connects and y-extent straddles the stem ends). The rhythm
/// pass counts overlapping `.beam` segments per stem to derive
/// eighth / sixteenth / thirty-second durations.
struct PathSegment: Equatable {
    enum Kind { case horizontal, vertical, rectangle, beam }
    var kind: Kind
    var rect: CGRect // collapsed bounding box; horizontal/vertical degenerate rects are 1-D
    var lineWidth: CGFloat
    var pageIndex: Int
}

/// A filled curved subpath captured from `c`/`v`/`y` Bezier operators —
/// the candidate geometry for a tie or slur. `bbox` is the page-space
/// bounding box; `leftPoint` / `rightPoint` are the extreme on-path
/// vertices (a tie's two notehead anchors). Ties are short, flat arcs
/// joining two SAME-pitch noteheads at adjacent x; slurs are longer or
/// join different pitches. The tie decoder filters on those criteria.
struct CurveArc: Equatable {
    var bbox: CGRect
    var leftPoint: CGPoint
    var rightPoint: CGPoint
    var pageIndex: Int
}

/// Semantic interpretation of a `RawGlyph` (PDFImporter+SMuFL).
/// `NoteDuration` and `UInt32` are `Equatable`, so synthesized
/// conformance carries through here.
enum SMuFLSemantic: Equatable {
    case noteheadBlack, noteheadHalf, noteheadWhole, noteheadDoubleWhole
    case stem, flag8thUp, flag8thDown, flag16thUp, flag16thDown,
         flag32ndUp, flag32ndDown, flag64thUp, flag64thDown
    case augmentationDot
    case rest(NoteDuration)
    case clefG, clefF, clefC, clefPercussion
    case clefG8vb // U+E052 gClef8vb — treble clef sounding an octave lower
    case accidentalSharp, accidentalFlat, accidentalNatural,
         accidentalDoubleSharp, accidentalDoubleFlat
    case timeSignatureDigit(Int) // 0-9
    case timeSignatureCommon, timeSignatureCutTime
    case staff5Lines // U+E003 (when MuseScore renders the staff as one glyph)
    case repeatBarlineDots
    case segno, coda, dalSegno, daCapo, fine, toCoda
    case fermata // out of scope but classified so it can be ignored cleanly
    case dynamic, articulation, ornament // out of scope buckets
    case unknown(UInt32) // emits info-diagnostic
}

/// A glyph with its semantic. Stage [3] output.
struct ClassifiedGlyph {
    var raw: RawGlyph
    var semantic: SMuFLSemantic
}

/// A non-music-glyph text run (lyrics, tempo text, title, …).
/// Captured as ordinary Unicode by the content-stream walker.
struct TextGlyph {
    var text: String
    var fontName: String
    var fontSize: CGFloat
    var origin: CGPoint
    var bbox: CGRect
    var pageIndex: Int
}

/// Output of stage [4]. One staff (5-line band) on a page.
struct Staff {
    var pageIndex: Int
    var yLines: [CGFloat] // five y-coordinates (top → bottom or bottom → top, fixed by detector)
    var xRange: ClosedRange<CGFloat>
    /// Vertical path segments inside `xRange` whose y-extent covers
    /// the full staff height. These become barline candidates.
    var barlineCandidates: [PathSegment]
}

/// Output of stage [5]. The page → system → part → staff → measure tree.
struct ImportSystem {
    var pageIndex: Int
    var yRange: ClosedRange<CGFloat>
    var parts: [ImportPart]
}

struct ImportPart {
    var staves: [ImportStaff]
}

struct ImportStaff {
    var staff: Staff
    var measures: [ImportMeasure]
}

struct ImportMeasure {
    /// Page-coordinate x range of this measure cell, used for x→time
    /// conversion in the voicing pass.
    var xRange: ClosedRange<CGFloat>
    var glyphs: [ClassifiedGlyph] // glyphs whose origin falls in xRange
    var leadingBarline: PathSegment? // path on the left edge
    var trailingBarline: PathSegment? // path on the right edge
    /// Five staff-line y-coordinates (ascending) for the staff this
    /// measure belongs to. Used by the pitch decoder to map notehead
    /// y → diatonic step. Empty when constructed by callers that
    /// don't need pitch information (e.g. ScoreState tests).
    var staffYLines: [CGFloat] = []
}

/// Stage [5b] output — score-state events, in x-order, per staff.
enum ScoreStateEvent {
    case clefChange(Clef, atMeasureIndex: Int)
    case timeSignature(TimeSignature, atMeasureIndex: Int)
    case keySignature(KeySignature, atMeasureIndex: Int)
    case tempo(Tempo, atMeasureIndex: Int)
}

// MARK: - Stage [6] rhythm decoding

/// Stem direction inferred from the relative y of the stem's far end
/// against the lead notehead. Local to the PDF importer; the public
/// score model has no equivalent flag (stems are auto-laid in
/// engraving, not stored on chords).
enum StemDirection: Equatable { case up, down }

/// Stage [6] output — one chord (or rest) decoded from a measure's
/// glyph cluster. `chord.notes.isEmpty` ⇔ this element is a rest;
/// the rest of the codebase uses the same "empty-notes Chord = rest"
/// convention (see `VoiceElement`).
struct RhythmElement {
    var chord: Chord
    var x: CGFloat
    var y: CGFloat
    var stemDirection: StemDirection?
    var beamGroup: Int?

    var isRest: Bool {
        chord.notes.isEmpty
    }
}
