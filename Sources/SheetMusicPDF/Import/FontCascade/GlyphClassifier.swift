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
        return Self.isLikelyMusicFont(ctFont: ctFont)
    }()

    private var cache: [UInt32: SMuFLSemantic] = [:]

    /// Tier-4 acceptance threshold. A nearest neighbor farther than this is
    /// reported `.unknown` rather than guessed. Measured against the Task 13
    /// ablation (Task 14): 0.15. Inert while `enableShapeMatching` is false
    /// (the default) or the per-font gate declines this font.
    nonisolated(unsafe) static var shapeAcceptanceThreshold = 0.15

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
    nonisolated(unsafe) static var musicFontGateBound = 0.10
    /// Fraction of the sample that must clear `musicFontGateBound` for the
    /// font to be treated as a music font. 0.5 sits in the middle of the
    /// measured gap (music fonts >= 0.72, text fonts <= 0.27).
    nonisolated(unsafe) static var musicFontGateFraction = 0.5
    /// Glyphs sampled per font when evaluating the gate. Evenly spread
    /// across the font's glyph-ID range (not the first N — subsetted PDF
    /// fonts often front-load Latin/ASCII glyph IDs even in a music face).
    nonisolated(unsafe) static var musicFontGateSampleSize = 40

    init(
        font: PDFImporter.EmbeddedFont?, enableShapeMatching: Bool = false,
        disableSMuFLTier: Bool = false, bypassMusicFontGate: Bool = false,
    ) {
        self.font = font
        self.enableShapeMatching = enableShapeMatching
        self.disableSMuFLTier = disableSMuFLTier
        self.bypassMusicFontGate = bypassMusicFontGate
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
        guard bestDistance <= Self.shapeAcceptanceThreshold else { return nil }
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
    static func isLikelyMusicFont(ctFont: CTFont) -> Bool {
        let glyphCount = Int(CTFontGetGlyphCount(ctFont))
        // gid 0 is `.notdef` in every font; start sampling at 1.
        guard glyphCount > 1 else { return false }
        let sampleTarget = min(glyphCount - 1, musicFontGateSampleSize)
        guard sampleTarget > 0 else { return false }
        let stride = max(1, (glyphCount - 1) / sampleTarget)
        var sampled = 0
        var hits = 0
        var gid = 1
        while gid < glyphCount, sampled < sampleTarget {
            defer { gid += stride }
            guard let path = CTFontCreatePathForGlyph(ctFont, CGGlyph(gid), nil),
                  !path.isEmpty else { continue }
            sampled += 1
            let descriptor = makeDescriptor(path: path)
            var best = Double.infinity
            for e in BravuraExemplars.all {
                let d = descriptor.distance(to: e.descriptor)
                if d < best { best = d }
            }
            if best <= musicFontGateBound { hits += 1 }
        }
        guard sampled > 0 else { return false }
        return Double(hits) / Double(sampled) >= musicFontGateFraction
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
