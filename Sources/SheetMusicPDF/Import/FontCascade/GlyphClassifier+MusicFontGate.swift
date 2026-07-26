#if canImport(CoreGraphics)
    import CoreGraphics
    import CoreText
#endif
import Foundation

/// The per-font MUSIC-FONT GATE: the population statistic that decides
/// whether Tier 4 may answer for a given font resource at all. Split out of
/// `GlyphClassifier.swift` to keep both files under the 400-line cap; it is
/// one cohesive unit (`isLikelyMusicFont` plus the two populations it tries
/// and the per-glyph primitive they share).
extension GlyphClassifier {
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
    /// Guards exactly the failure measured before the gate existed: at the
    /// placeholder threshold with NO gate, Tier 4 matched a CJK lyric font's
    /// (e.g. Hiragino) outlines to Bravura exemplars just as readily as a real
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
    ///    Courier New, Arial). Review caught the bug this replaces: the OLD
    ///    single population (below) strided evenly across
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
    ///    needs: a font subsetted into a PDF is measured NOT to
    ///    preserve its original Unicode cmap, so `cmapReachableExemplarVerdict`
    ///    always returns nil for them (measured: 0 of 60 codepoints
    ///    resolve on every embedded font across the real corpus, music or
    ///    text) and this fallback is what the weights were calibrated on.
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
    /// subsetted PDF font's cmap does not survive subsetting (measured) —
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
}
