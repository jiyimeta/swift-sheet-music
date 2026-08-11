#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
import SheetMusicCore

// A canonical order for the four front-end streams, imposed ONCE at
// `buildScore`'s door so no pass downstream can observe the order its input
// arrived in.
//
// WHY THIS EXISTS, AND WHY IT IS NOT THIRTY COMPARATOR FIXES.
//
// A raster front-end cannot reproduce a PDF's content-stream order — it finds
// glyphs on a page. So `buildScore` has to be a function of the CONTENT of its
// streams, not of their order, and gate P0-G1 asserts exactly that by decoding
// the same page twice: once in content-stream order, once from a
// position-sorted label file. Measured 2026-08-11 over 2208 renders, it was
// not: `exact=1574/2208`, diverging on durations, pitches, dots, voices,
// tuplets and lyric attachment.
//
// The obvious repair — make every comparator a total order — is both larger
// and insufficient:
//
//   - Most of the order-dependent decisions are NOT sorts. They are first-min
//     scans (`nearestStem`'s cost tie, `nearestNotehead`'s dx+dy tie), greedy
//     claims that consume candidates in arrival order (tuplet marks, rhythm
//     repair candidates), and "break at the first content glyph" scans in the
//     clef / key / time readers. No comparator change reaches those.
//   - Two comparators sort on an epsilon band (`|Δy| > ε ? y : x`, in
//     `PDFImporter+Text` and `PDFImporter+Lyrics`). That relation is not
//     transitive, so it is not a strict weak ordering at all, and no
//     additional key repairs it.
//
// One sort at the boundary reaches all of them, because every array any pass
// ever sees is an order-preserving `filter` of one of these four streams —
// `ImportMeasure.glyphs` (PDFImporter+Layout), `stems` / `beams`
// (PDFImporter+Rhythm), lyric candidates (PDFImporter+Lyrics), tie arcs
// (PDFImporter+Ties). Fix the order of the streams and every derived array is
// a pure function of the stream's CONTENTS.
//
// Note what this does and does not claim about `sorted(by:)`. Swift's sort is
// not documented as stable, but it IS deterministic: the same input array
// yields the same output. The bug was never that ties resolve randomly — it
// was that the tied elements arrived in different orders in the two walks.
// Canonicalizing the input removes that difference, which is why the existing
// comparators can stay exactly as they are.
//
// THE ONE BEHAVIOUR CHANGE. Where a real PDF's content-stream order disagreed
// with this order at a consequential tie, the decode now resolves the tie the
// other way. The class of case is narrow: two same-pitch noteheads in one
// cluster (an F# and a Gb are the same midi at different y) get a
// geometrically-determined dedup survivor instead of a content-stream one,
// which can move that chord's tie marks. That is a re-bless, not a regression
// — and `PDFImporter+Rhythm`'s `chordNoteOrder` is untouched: it still keys on
// `(pitch, position)`, and this sort only makes its `position` tiebreak
// reproducible.
//
// Geometry-first is deliberately NOT the ordering `chordNoteOrder` rejects.
// That doc comment argues against ordering a chord's NOTES by y, where pitch
// exists and the dedup survivor is load-bearing. Here there are no notes yet,
// only ink: y-then-x is simply reading order, and every remaining field
// participates so the order is total up to genuinely identical elements.
extension WalkedContent {
    /// The same content, in a canonical order.
    ///
    /// Total: the keys cover every stored field, so two elements compare equal
    /// only when they are the same value — and equal values are
    /// interchangeable for every consumer, including the glyph-keyed side
    /// tables (`ClassifiedGlyph` is `Hashable` and keyed by value).
    func canonicalized() -> WalkedContent {
        WalkedContent(
            glyphs: glyphs.sorted(by: PDFImporterCanonicalOrder.precedes),
            texts: texts.sorted(by: PDFImporterCanonicalOrder.precedes),
            paths: paths.sorted(by: PDFImporterCanonicalOrder.precedes),
            curves: curves.sorted(by: PDFImporterCanonicalOrder.precedes),
        )
    }
}

enum PDFImporterCanonicalOrder {
    /// Lexicographic over the key vectors, written as `<` / `>` rather than
    /// `!=` so a non-finite coordinate cannot make the relation asymmetric.
    private static func precedes(_ a: [Double], _ b: [Double]) -> Bool {
        for (x, y) in zip(a, b) {
            if x < y { return true }
            if y < x { return false }
        }
        return a.count < b.count
    }

    // MARK: - Glyphs

    /// Page, then BOTTOM-UP, then left to right, with every remaining field as
    /// a tiebreak.
    ///
    /// Bottom-up rather than reading order, and the direction was MEASURED,
    /// not reasoned. Both directions are equally total, so the invariance gate
    /// cannot choose between them — but the choice is not neutral downstream:
    /// the first notehead of a same-x cluster becomes that chord's LEAD
    /// (`decodeRhythm`), and the lead anchors both the stem direction
    /// (`stem.rect.midY > lead.origin.y`) and the augmentation-dot window.
    ///
    /// Over the 141-score corpus gate (curated 6 + real 135), against the
    /// pre-canonicalization baseline:
    ///
    ///   top-first (`-y`):    13 scores moved, 12 of them WORSE
    ///                        (dur% −1 to −3, pitch% −1)
    ///   bottom-first (`+y`):  3 scores moved, ALL BETTER, none worse
    ///                        (mimicopy_ラストオーダー dur% 97→98,
    ///                         革命道中 dur% 99→100)
    ///
    /// The mechanism agrees: a chord's stem runs upward from its LOWEST
    /// notehead, so with the lowest as lead `stem.midY > lead.y` reads `.up`,
    /// which is right for the common case. (It is not right for every case —
    /// a down-stem chord wants its highest notehead as lead, so no fixed
    /// direction is universally correct. Making those decisions independent of
    /// the lead entirely is the real repair, and a separate one.)
    static func precedes(_ a: ClassifiedGlyph, _ b: ClassifiedGlyph) -> Bool {
        precedes(key(a), key(b))
    }

    private static func key(_ g: ClassifiedGlyph) -> [Double] {
        [
            Double(g.geometry.pageIndex),
            Double(g.geometry.origin.y),
            Double(g.geometry.origin.x),
        ]
            + semanticKey(g.semantic)
            + [
                Double(g.geometry.advance),
                Double(g.geometry.renderedSize),
                Double(g.geometry.fontSize),
            ]
    }

    /// A total rank over `SMuFLSemantic`, associated values included.
    ///
    /// Hand-written rather than derived: the enum is not `CaseIterable` (three
    /// cases carry payloads) and `RawRepresentable` would force the payloads
    /// out. The numbers are ordering only — nothing reads them as meaning —
    /// so a case added upstream can take any unused rank, but it MUST take
    /// one: a case that falls through to a shared rank makes two different
    /// glyphs tie, and the order stops being total.
    private static func semanticKey(_ s: SMuFLSemantic) -> [Double] {
        switch s {
        case .brace: [0, 0]
        case .noteheadBlack: [1, 0]
        case .noteheadHalf: [2, 0]
        case .noteheadWhole: [3, 0]
        case .noteheadDoubleWhole: [4, 0]
        case .noteheadXBlack: [5, 0]
        case .noteheadXHalf: [6, 0]
        case .noteheadXWhole: [7, 0]
        case .stem: [8, 0]
        case .flag8thUp: [9, 0]
        case .flag8thDown: [10, 0]
        case .flag16thUp: [11, 0]
        case .flag16thDown: [12, 0]
        case .flag32ndUp: [13, 0]
        case .flag32ndDown: [14, 0]
        case .flag64thUp: [15, 0]
        case .flag64thDown: [16, 0]
        case .augmentationDot: [17, 0]
        case let .rest(duration): [18] + durationKey(duration)
        case .clefG: [19, 0]
        case .clefF: [20, 0]
        case .clefC: [21, 0]
        case .clefPercussion: [22, 0]
        case .clefG8vb: [23, 0]
        case .clefG8va: [24, 0]
        case .clefG15ma: [25, 0]
        case .clefG15mb: [26, 0]
        case .clefF8va: [27, 0]
        case .clefF8vb: [28, 0]
        case .clefF15ma: [29, 0]
        case .clefF15mb: [30, 0]
        case .accidentalSharp: [31, 0]
        case .accidentalFlat: [32, 0]
        case .accidentalNatural: [33, 0]
        case .accidentalDoubleSharp: [34, 0]
        case .accidentalDoubleFlat: [35, 0]
        case let .timeSignatureDigit(digit): [36, Double(digit)]
        case .timeSignatureCommon: [37, 0]
        case .timeSignatureCutTime: [38, 0]
        case .staff5Lines: [39, 0]
        case .repeatBarlineDots: [40, 0]
        case .segno: [41, 0]
        case .coda: [42, 0]
        case .dalSegno: [43, 0]
        case .daCapo: [44, 0]
        case .fine: [45, 0]
        case .toCoda: [46, 0]
        case .fermata: [47, 0]
        case .dynamic: [48, 0]
        case .articulation: [49, 0]
        case .ornament: [50, 0]
        case let .unknown(codepoint): [51, Double(codepoint)]
        }
    }

    /// `.fraction` carries two integers, so it needs two slots of its own —
    /// ranking it by its numeric value would tie 1/2 with 2/4, which are
    /// distinct values of a `Hashable` enum and therefore distinct glyphs.
    private static func durationKey(_ d: NoteDuration) -> [Double] {
        switch d {
        case .whole: [0, 0, 0]
        case .half: [1, 0, 0]
        case .quarter: [2, 0, 0]
        case .eighth: [3, 0, 0]
        case .sixteenth: [4, 0, 0]
        case .thirtySecond: [5, 0, 0]
        case .sixtyFourth: [6, 0, 0]
        case .oneTwentyEighth: [7, 0, 0]
        case .twoFiftySixth: [8, 0, 0]
        case let .fraction(f): [9, Double(f.numerator), Double(f.denominator)]
        case .measure: [10, 0, 0]
        }
    }

    // MARK: - Paths

    static func precedes(_ a: PathSegment, _ b: PathSegment) -> Bool {
        precedes(key(a), key(b))
    }

    private static func key(_ p: PathSegment) -> [Double] {
        [
            Double(p.pageIndex),
            kindRank(p.kind),
            -Double(p.rect.maxY),
            Double(p.rect.minX),
            Double(p.rect.width),
            Double(p.rect.height),
            Double(p.lineWidth),
        ]
            + quadKey(p.quad)
    }

    private static func kindRank(_ kind: PathSegment.Kind) -> Double {
        switch kind {
        case .horizontal: 0
        case .vertical: 1
        case .rectangle: 2
        case .beam: 3
        }
    }

    /// A `.beam`'s quad is the only field two segments can differ in after the
    /// rect: an axis-aligned box inflates a sloped beam, so two beams of
    /// opposite slope can share one. Absent quads sort first, and cannot tie
    /// with a present one.
    private static func quadKey(_ quad: BeamQuad?) -> [Double] {
        guard let quad else { return [0] }
        return [
            1,
            Double(quad.xRange.lowerBound),
            Double(quad.xRange.upperBound),
            Double(quad.topSlope),
            Double(quad.topIntercept),
            Double(quad.botSlope),
            Double(quad.botIntercept),
            Double(quad.pageIndex),
        ]
    }

    // MARK: - Texts

    /// Reading order, then the run's own content. `text` and `fontName` are
    /// compared as strings before the numeric tail, so two runs at one origin
    /// order by what they say.
    static func precedes(_ a: TextGlyph, _ b: TextGlyph) -> Bool {
        let ka = [Double(a.pageIndex), -Double(a.origin.y), Double(a.origin.x)]
        let kb = [Double(b.pageIndex), -Double(b.origin.y), Double(b.origin.x)]
        if precedes(ka, kb) { return true }
        if precedes(kb, ka) { return false }
        if a.text != b.text { return a.text < b.text }
        if a.fontName != b.fontName { return a.fontName < b.fontName }
        // `bbox` is documented as never populated, so it contributes nothing
        // today — included anyway, because leaving a stored field out of a
        // "total" order is a trap for whoever eventually populates it.
        return precedes(
            [
                Double(a.fontSize),
                Double(a.renderedSize),
                Double(a.bbox.minX),
                Double(a.bbox.minY),
                Double(a.bbox.width),
                Double(a.bbox.height),
            ],
            [
                Double(b.fontSize),
                Double(b.renderedSize),
                Double(b.bbox.minX),
                Double(b.bbox.minY),
                Double(b.bbox.width),
                Double(b.bbox.height),
            ],
        )
    }

    // MARK: - Curves

    static func precedes(_ a: CurveArc, _ b: CurveArc) -> Bool {
        precedes(key(a), key(b))
    }

    private static func key(_ c: CurveArc) -> [Double] {
        [
            Double(c.pageIndex),
            -Double(c.leftPoint.y),
            Double(c.leftPoint.x),
            -Double(c.rightPoint.y),
            Double(c.rightPoint.x),
            Double(c.bbox.minX),
            -Double(c.bbox.maxY),
            Double(c.bbox.width),
            Double(c.bbox.height),
        ]
    }
}
