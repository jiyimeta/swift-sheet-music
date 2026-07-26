#if canImport(CoreGraphics)
    import CoreGraphics
    import CoreText
#endif
import Foundation

/// Classify a glyph to a `SMuFLSemantic` through a tiered cascade, so a PDF
/// whose music font is not SMuFL-encoded still decodes.
///
/// Tier 1 SMuFL PUA codepoint — authoritative, and the ONLY tier that fires for
///        MuseScore / Dorico / Finale 27+ output. Existing behavior.
/// Tier 2 glyph NAME from `/Encoding /Differences` — exact where names survive
///        subsetting.
/// Tier 4 outline SHAPE matched against Bravura exemplars — the general case.
///
/// (Tier 3, a per-font codepoint table, is deliberately not implemented: Tier 4
/// is its general-case superset. Add it only if a real font defeats Tier 4.)
///
/// One instance per font resource; exemplar and outline work is cached, so a
/// document with tens of distinct glyphs pays the cost once per glyph.
final class GlyphClassifier {
    private let font: PDFImporter.EmbeddedFont?
    /// The CALLER's request to enable Tier 4 (outline shape matching).
    /// **Default false** — see `PDFImportOptions.enableShapeMatching`. Even
    /// when true, `effectiveShapeMatching` still gates Tier 4 off per-font
    /// unless `isLikelyMusicFont` accepts this font's glyph population — see
    /// that function's doc comment for why a global on/off switch alone is
    /// unsafe (measured on ギブス.pdf: 0 of 4254 glyphs left `.unknown` and
    /// lyric recall collapsed from 92% to 0% without the gate).
    private let enableShapeMatching: Bool
    /// TESTING ONLY. Suppresses Tier 1 (SMuFL codepoint) so the cascade falls
    /// through to Tier 2 / Tier 4 for measurement against Tier 1's
    /// known-correct answer. See `PDFImportOptions.disableSMuFLCodepointTier`.
    private let disableSMuFLTier: Bool
    /// TESTING ONLY. Skips `isLikelyMusicFont` so `enableShapeMatching` alone
    /// decides Tier 4 eligibility. See
    /// `PDFImportOptions.bypassMusicFontGateForTesting`.
    private let bypassMusicFontGate: Bool
    /// Per-instance copies of the gate knobs below — see their `default*`
    /// constants for the production values and rationale. Instance
    /// (rather than shared mutable `static var`) so a test can override one
    /// classifier's gate behavior without any risk of a concurrently
    /// running suite's `GlyphClassifier` observing the mutation — Swift
    /// Testing runs suites in parallel by default, and a `static var` here
    /// previously let `PDFImporterShapeMatchingGateTests` intermittently
    /// pollute `GlyphClassifierTests` (Task 15 final review, C1).
    private let shapeAcceptanceThreshold: Double
    private let musicFontGateBound: Double
    private let musicFontGateFraction: Double
    private let musicFontGateSampleSize: Int
    private lazy var ctFont: CTFont? = {
        guard let program = font?.program, let kind = font?.programKind
        else { return nil }
        return makeCTFont(program: program, kind: kind)
    }()

    /// `enableShapeMatching` narrowed by the per-font music-font gate — the
    /// value every call site inside this class actually consults. Computed
    /// once per instance (one `GlyphClassifier` per font resource per page,
    /// per the type doc comment) since `isLikelyMusicFont` rasterizes and
    /// compares a glyph sample, which is not free.
    private lazy var effectiveShapeMatching: Bool = {
        guard enableShapeMatching, let ctFont else { return false }
        if bypassMusicFontGate { return true }
        return Self.isLikelyMusicFont(
            ctFont: ctFont, sampleSize: musicFontGateSampleSize,
            bound: musicFontGateBound, fraction: musicFontGateFraction,
        )
    }()

    private var cache: [UInt32: SMuFLSemantic] = [:]

    /// Tier-4 acceptance threshold. A nearest neighbor farther than this is
    /// reported `.unknown` rather than guessed. Measured against the Task 13
    /// ablation (Task 14): 0.15. Inert while `enableShapeMatching` is false
    /// (the default) or the per-font gate declines this font.
    static let defaultShapeAcceptanceThreshold = 0.15

    /// Per-glyph distance bound for the music-font gate's SAMPLING pass
    /// (`isLikelyMusicFont`) — deliberately TIGHTER than
    /// `shapeAcceptanceThreshold` (0.30 was tried first and rejected; see
    /// task-14-report.md). At 0.15-0.30, ordinary TEXT glyphs (Latin
    /// letters, CJK ideographs) land close enough to SOME Bravura exemplar
    /// by sheer silhouette coincidence — after bbox-fit normalization, a
    /// dense round CJK character or a bold Latin letterform is "just a dark
    /// blob", indistinguishable at a loose bound from a notehead or clef.
    /// Measured across the corpus's real embedded fonts: at bound 0.10 the
    /// real music faces (Leland, MScore) sample 72-88% of their glyphs
    /// within bound, while every text face (Edwin, FreeSerif, Hiragino*,
    /// LucidaGrande, Helvetica) samples 27% or less — a wide, clean margin.
    static let defaultMusicFontGateBound = 0.10
    /// Fraction of the sample that must clear `musicFontGateBound` for the
    /// font to be treated as a music font. 0.5 sits in the middle of the
    /// measured gap (music fonts >= 0.72, text fonts <= 0.27).
    static let defaultMusicFontGateFraction = 0.5
    /// Glyphs sampled per font when evaluating the gate's raw-glyph-ID
    /// FALLBACK population (see `isLikelyMusicFont`). Evenly spread across
    /// the font's glyph-ID range (not the first N — subsetted PDF fonts
    /// often front-load Latin/ASCII glyph IDs even in a music face).
    static let defaultMusicFontGateSampleSize = 40

    init(
        font: PDFImporter.EmbeddedFont?, enableShapeMatching: Bool = false,
        disableSMuFLTier: Bool = false, bypassMusicFontGate: Bool = false,
        shapeAcceptanceThreshold: Double = GlyphClassifier.defaultShapeAcceptanceThreshold,
        musicFontGateBound: Double = GlyphClassifier.defaultMusicFontGateBound,
        musicFontGateFraction: Double = GlyphClassifier.defaultMusicFontGateFraction,
        musicFontGateSampleSize: Int = GlyphClassifier.defaultMusicFontGateSampleSize,
    ) {
        self.font = font
        self.enableShapeMatching = enableShapeMatching
        self.disableSMuFLTier = disableSMuFLTier
        self.bypassMusicFontGate = bypassMusicFontGate
        self.shapeAcceptanceThreshold = shapeAcceptanceThreshold
        self.musicFontGateBound = musicFontGateBound
        self.musicFontGateFraction = musicFontGateFraction
        self.musicFontGateSampleSize = musicFontGateSampleSize
    }

    /// True when this font can be classified without a `/ToUnicode` CMap.
    /// With Tier 4 off (the default), only a non-empty `/Differences` map
    /// (Tier 2) qualifies — a CMap-less font with nothing but an embedded
    /// program has no tier available to consult, so walking it byte-by-byte
    /// in the no-CMap path (`emitShowSimpleFont`) would be pure overhead.
    /// With Tier 4 on, a usable embedded font program also qualifies.
    var canClassifyWithoutCMap: Bool {
        if let font, !font.differences.isEmpty { return true }
        return effectiveShapeMatching && ctFont != nil
    }

    func classify(codepoint: UInt32, glyphID: CGGlyph?) -> SMuFLSemantic {
        if let hit = cache[codepoint] { return hit }
        let result = uncachedClassify(codepoint: codepoint, glyphID: glyphID)
        cache[codepoint] = result
        return result
    }

    private func uncachedClassify(
        codepoint: UInt32, glyphID: CGGlyph?,
    ) -> SMuFLSemantic {
        // Tier 1 — SMuFL PUA codepoint.
        if !disableSMuFLTier {
            let tier1 = PDFImporter.smuflSemantic(codepoint: codepoint)
            if case .unknown = tier1 {} else { return tier1 }
        }

        // Tier 2 — glyph name.
        if let name = font?.differences[codepoint],
           let tier2 = GlyphNameTable.semantic(glyphName: name)
        {
            return tier2
        }

        // Tier 4 — outline shape match. Off by default, and further gated
        // per-font even when the caller enables it; see
        // `effectiveShapeMatching`'s doc comment.
        if effectiveShapeMatching,
           let semantic = classifyByShape(codepoint: codepoint, glyphID: glyphID)
        {
            return semantic
        }
        return .unknown(codepoint)
    }

    private func classifyByShape(
        codepoint: UInt32, glyphID: CGGlyph?,
    ) -> SMuFLSemantic? {
        guard let ctFont, let path = outline(ctFont: ctFont, glyphID: glyphID),
              !path.isEmpty else { return nil }
        let probe = makeDescriptor(path: path)
        var best: SMuFLSemantic?
        var bestDistance = Double.infinity
        // Iterate the exemplar ARRAY (ordered), never a Set / Dictionary —
        // the front-end determinism contract.
        for e in BravuraExemplars.all {
            let d = probe.distance(to: e.descriptor)
            if d < bestDistance {
                bestDistance = d
                best = e.semantic
            }
        }
        guard bestDistance <= shapeAcceptanceThreshold else { return nil }
        return best
    }

    /// Semantics Tier 4 CANNOT distinguish, measured against Bravura in Task 11.
    ///
    /// `restWhole` (U+E4E3) and `restHalf` (U+E4E4) are the same 282×144
    /// rectangle in Bravura, differing only by a 133-unit vertical offset
    /// (raw bboxes `(0, -135, 282, 144)` vs `(0, -2, 282, 144)`); after
    /// `normalizedBitmap` centres the bounding box their descriptors are
    /// byte-identical, margin 0.0000. Which one a glyph is depends on its
    /// position relative to the staff — information Tier 4 never sees.
    ///
    /// DECISION: guess `.rest(.whole)` rather than decline. Declining would
    /// drop the glyph entirely, losing the rest and shifting every later
    /// element in the bar; a wrong-duration rest is visible and correctable.
    /// The existing metric-sum reconciliation cannot repair either case — it
    /// never re-values rests — so the choice is between a visible error and a
    /// structural one. Whole rests (empty bars) are also the commoner glyph.
    static let tier4AmbiguousRests: Set<SMuFLSemantic> = [
        .rest(.whole), .rest(.half),
    ]

    /// Decides whether `ctFont` is plausibly a MUSIC font — i.e. whether
    /// Tier 4 should be allowed to answer for ANY of its glyphs — by
    /// sampling its glyph population rather than consulting a font-name
    /// allowlist.
    ///
    /// A name list is brittle: it drifts across vendors (Bravura, Leland,
    /// MScore, Emmentaler, Petaluma, …) and versions, and a subsetted PDF
    /// font's `/BaseFont` name is frequently mangled by the subsetting
    /// prefix or missing entirely. A population statistic generalizes: a
    /// real music font's glyphs are, in bulk, outline-shaped like Bravura's
    /// (noteheads, stems, clefs, rests, …); a text font's are not, no
    /// matter what it happens to be named.
    ///
    /// Guards exactly the failure Task 12 measured: at the placeholder
    /// threshold with NO gate, Tier 4 matched a CJK lyric font's (e.g.
    /// Hiragino) outlines to Bravura exemplars just as readily as a real
    /// music font's outlines, leaving 0 of 4254 glyphs `.unknown` on
    /// ギブス.pdf and collapsing lyric recall from 92% to 0%.
    ///
    /// TWO populations are tried, in order:
    ///
    /// 1. `cmapReachableExemplarVerdict` — the 60 exemplar codepoints
    ///    (`BravuraExemplars.codepoints`), looked up in `ctFont`'s OWN
    ///    cmap. This is the population that actually separates a full or
    ///    lightly-subsetted SMuFL font from a full text font: a real SMuFL
    ///    face declares Unicode mappings for its PUA notation codepoints and
    ///    those glyphs are shaped like Bravura's by construction, while an
    ///    ordinary text font has no cmap entries in that range AT ALL (this
    ///    is required — 5 full system faces measured zero reachable
    ///    exemplar codepoints: Helvetica, Hiragino Sans, Times New Roman,
    ///    Courier New, Arial). Task 15's final review caught the bug this
    ///    replaces: the OLD single population (below) strided evenly across
    ///    a FULL font's entire glyph-ID range, so a full, unsubsetted SMuFL
    ///    font — the bundled Bravura.otf itself — sampled mostly exotic,
    ///    non-exemplar-shaped glyphs (ornaments, obscure figured-bass
    ///    marks, …) and scored 0.20, well under the 0.5 acceptance
    ///    fraction. Reading the exemplar codepoints back through the font's
    ///    cmap instead of striding blind fixes that: full Bravura scores a
    ///    clean 1.0 (all 60 resolve, all within bound).
    /// 2. Falls back to the raw-glyph-ID stride sample (unchanged from
    ///    before this fix) when fewer than `cmapExemplarMinimum` codepoints
    ///    resolve. This is the population every corpus PDF's embedded music
    ///    font (Leland, MScore, subsetted Bravura, Finale's Kousaku) still
    ///    needs: Task 8 proved a font subsetted into a PDF does NOT
    ///    preserve its original Unicode cmap, so `cmapReachableExemplarVerdict`
    ///    always returns nil for them (measured: 0 of 60 codepoints
    ///    resolve on every embedded font across the real corpus, music or
    ///    text) and this fallback is what Task 14 actually calibrated.
    static func isLikelyMusicFont(
        ctFont: CTFont,
        sampleSize: Int = defaultMusicFontGateSampleSize,
        bound: Double = defaultMusicFontGateBound,
        fraction: Double = defaultMusicFontGateFraction,
    ) -> Bool {
        if let verdict = cmapReachableExemplarVerdict(ctFont: ctFont, bound: bound, fraction: fraction) {
            return verdict
        }
        return isLikelyMusicFontByRawGlyphIDs(
            ctFont: ctFont, sampleSize: sampleSize, bound: bound, fraction: fraction,
        )
    }

    /// Minimum number of the 60 exemplar codepoints (`BravuraExemplars.
    /// codepoints`) that must resolve through `ctFont`'s own cmap before
    /// that population is trusted over the raw-glyph-ID fallback. Guards
    /// against a coincidental cmap hit on a handful of PUA codepoints in an
    /// unrelated font (icon fonts are known to squat on Private Use Area
    /// codepoints too) being read as "this is a music font" from too small
    /// a sample. Every real case measured is bimodal, not borderline: 0
    /// reachable (every subsetted PDF font and every full text font tried)
    /// or 60 (the full bundled Bravura.otf) — this threshold sits well
    /// clear of both.
    private static let cmapExemplarMinimum = 10

    /// The cmap-reachable-exemplar population (see `isLikelyMusicFont`'s
    /// doc comment). Returns nil — "no verdict, consult the fallback" —
    /// when fewer than `cmapExemplarMinimum` of the 60 exemplar codepoints
    /// resolve to a real outline through `ctFont`'s own cmap.
    private static func cmapReachableExemplarVerdict(
        ctFont: CTFont, bound: Double, fraction: Double,
    ) -> Bool? {
        var sampled = 0
        var hits = 0
        for codepoint in BravuraExemplars.codepoints {
            guard let scalar = Unicode.Scalar(codepoint) else { continue }
            var units = Array(String(scalar).utf16)
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            guard CTFontGetGlyphsForCharacters(ctFont, &units, &glyphs, units.count),
                  let gid = glyphs.first, gid != 0,
                  let hit = gateSampleHit(ctFont: ctFont, gid: gid, bound: bound)
            else { continue }
            sampled += 1
            if hit { hits += 1 }
        }
        guard sampled >= cmapExemplarMinimum else { return nil }
        return Double(hits) / Double(sampled) >= fraction
    }

    /// The pre-Task-15 population: `sampleSize` glyph IDs evenly strided
    /// across the font's own glyph-ID range, starting at 1 (gid 0 is
    /// `.notdef` in every font). Reached by RAW GLYPH ID because a
    /// subsetted PDF font's cmap does not survive subsetting (Task 8) —
    /// this is the population that still has to serve every embedded music
    /// font in the real corpus.
    private static func isLikelyMusicFontByRawGlyphIDs(
        ctFont: CTFont, sampleSize: Int, bound: Double, fraction: Double,
    ) -> Bool {
        let glyphCount = Int(CTFontGetGlyphCount(ctFont))
        guard glyphCount > 1 else { return false }
        let sampleTarget = min(glyphCount - 1, sampleSize)
        guard sampleTarget > 0 else { return false }
        let stride = max(1, (glyphCount - 1) / sampleTarget)
        var sampled = 0
        var hits = 0
        var gid = 1
        while gid < glyphCount, sampled < sampleTarget {
            defer { gid += stride }
            guard let hit = gateSampleHit(ctFont: ctFont, gid: CGGlyph(gid), bound: bound)
            else { continue }
            sampled += 1
            if hit { hits += 1 }
        }
        guard sampled > 0 else { return false }
        return Double(hits) / Double(sampled) >= fraction
    }

    /// Shared per-glyph gate primitive for both populations above: true /
    /// false is "sampled, and within / outside `bound` of some exemplar";
    /// nil is "not sampled" (glyph ID has no outline — `.notdef` or a blank
    /// glyph — so it doesn't count toward the sample size either way).
    private static func gateSampleHit(ctFont: CTFont, gid: CGGlyph, bound: Double) -> Bool? {
        guard let path = CTFontCreatePathForGlyph(ctFont, gid, nil), !path.isEmpty
        else { return nil }
        let descriptor = makeDescriptor(path: path)
        var best = Double.infinity
        for e in BravuraExemplars.all {
            let d = descriptor.distance(to: e.descriptor)
            if d < best { best = d }
        }
        return best <= bound
    }

    /// Outlines are reached by RAW GLYPH ID only.
    ///
    /// Task 8 proved that a font subsetted into a PDF does NOT preserve its
    /// original Unicode cmap or `post` names: on the embedded Leland subset a
    /// U+E0A4 lookup FAILED and names came back as synthetic `gid0`…`gid24`.
    /// So `CTFontGetGlyphsForCharacters` cannot be used as a fallback here —
    /// it would silently return no glyph for exactly the fonts this tier
    /// exists to serve. Callers must supply the glyph ID from the PDF content
    /// stream (for Identity-H, the CID is the glyph ID).
    private func outline(ctFont: CTFont, glyphID: CGGlyph?) -> CGPath? {
        guard let glyphID, glyphID != 0 else { return nil }
        return CTFontCreatePathForGlyph(ctFont, glyphID, nil)
    }
}
