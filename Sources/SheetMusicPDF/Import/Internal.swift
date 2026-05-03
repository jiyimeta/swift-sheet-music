import CoreGraphics
import Foundation
import PDFKit
import SheetMusicCore

// Internal types shared across `PDFImporter+<Stage>` extensions. All
// declarations here are deliberately `internal` (default visibility) —
// only the `PDFImporter` façade and `PDFImportOptions` are public.

/// Raw glyph captured from one Tj / TJ operator. Position is the
/// text origin in PDF page coordinates (origin = bottom-left).
struct RawGlyph: Equatable {
    var codepoint: UInt32 // Unicode scalar (often a SMuFL PUA codepoint)
    var fontName: String // PostScript name as reported by PDFKit
    var fontSize: CGFloat // points
    var origin: CGPoint
    var advance: CGFloat // horizontal advance to the next glyph in points
    var pageIndex: Int
}

/// One straight or rectangular path segment captured from m/l/re
/// content-stream operators. Used by staff-line and barline detection.
struct PathSegment: Equatable {
    enum Kind { case horizontal, vertical, rectangle }
    var kind: Kind
    var rect: CGRect // collapsed bounding box; horizontal/vertical degenerate rects are 1-D
    var lineWidth: CGFloat
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
}

/// Stage [5b] output — score-state events, in x-order, per staff.
enum ScoreStateEvent {
    case clefChange(Clef, atMeasureIndex: Int)
    case timeSignature(TimeSignature, atMeasureIndex: Int)
    case keySignature(KeySignature, atMeasureIndex: Int)
    case tempo(Tempo, atMeasureIndex: Int)
}
