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
    /// Internal, not private, because `resolveGlyphID` lives in
    /// `GlyphClassifier+GlyphIDResolve.swift` (this file is at the 400-line
    /// cap) and needs both this and `ctFont`.
    let font: PDFImporter.EmbeddedFont?
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
    /// pollute `GlyphClassifierTests`.
    private let shapeAcceptanceThreshold: Double
    private let musicFontGateBound: Double
    private let musicFontGateFraction: Double
    private let musicFontGateSampleSize: Int
    lazy var ctFont: CTFont? = {
        guard let program = font?.program else { return nil }
        return makeCTFont(program: program)
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

    /// Cache key. EVERY component is part of it because the tiers disagree
    /// about what the answer depends on: Tier 1 reads only the codepoint,
    /// Tier 2 only the character code, Tier 4 only the glyph ID's outline. A
    /// subsetted font routinely decodes several CIDs to one Unicode scalar —
    /// unmapped CIDs collapse onto a single scalar — so keying by codepoint
    /// alone would hand every one of them the first CID's outline verdict.
    private struct CacheKey: Hashable {
        var codepoint: UInt32
        var characterCode: UInt32?
        var glyphID: CGGlyph?
    }

    private var cache: [CacheKey: SMuFLSemantic] = [:]
    /// Character code → resolved glyph ID, including the negative answer —
    /// see `resolveGlyphID`, which walks several cmap strategies per miss.
    var glyphIDCache: [UInt32: CGGlyph?] = [:]

    /// Tier-4 acceptance threshold. A nearest neighbor farther than this is
    /// reported `.unknown` rather than guessed. Measured against the Tier-1
    /// ablation over the real corpus: 0.15. Inert while `enableShapeMatching` is false
    /// (the default) or the per-font gate declines this font.
    static let defaultShapeAcceptanceThreshold = 0.15

    /// Per-glyph distance bound for the music-font gate's SAMPLING pass
    /// (`isLikelyMusicFont`) — deliberately TIGHTER than
    /// `shapeAcceptanceThreshold` (0.30 was tried first and rejected).
    /// At 0.15-0.30, ordinary TEXT glyphs (Latin
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

    /// Whether Tier 2 may read this font's TEXT-AMBIGUOUS glyph names — the
    /// AGL digit words `zero`…`nine`; see `GlyphNameTable.textAmbiguousTable`.
    /// Requires positive evidence that this resource is a music font, because
    /// those names are how EVERY producer re-encodes an ordinary text font's
    /// digits, and reading them as time-signature digits invents time
    /// signatures and mm-rest counts out of body text.
    ///
    /// Two independent kinds of evidence, cheapest first:
    ///
    /// 1. The font's own `/Differences` names a glyph only a music font has
    ///    (a notehead, a clef, a rest, …). This costs nothing, needs no
    ///    embedded program, and covers the legacy faces this tier exists for
    ///    — Maestro, Opus and Sonata all name their full notation repertoire.
    /// 2. Otherwise, the Tier-4 per-font music-font gate, when Tier 4 is on
    ///    and accepts this font. Deliberately NOT consulted when Tier 4 is
    ///    off: that gate rasterizes a 40-glyph sample against 60 exemplars,
    ///    and paying that on every `/Differences` text font of every ordinary
    ///    PDF would be a real cost on the default path, to rescue only the
    ///    narrow case of a music resource whose encoding names digits and
    ///    NOTHING else — which Tier 2 alone could not usefully decode anyway.
    private lazy var acceptsTextAmbiguousNames: Bool = {
        if let font, font.differences.values.contains(
            where: GlyphNameTable.isUnambiguousMusicName,
        ) {
            // Order-independent: an any-match over a Dictionary's values is
            // a set predicate, so this respects the determinism contract
            // even though `differences` has no defined iteration order.
            return true
        }
        return effectiveShapeMatching
    }()

    /// True when this font can be classified without a `/ToUnicode` CMap.
    /// With Tier 4 off (the default), only a `/Differences` map naming at
    /// least one glyph Tier 2 can actually resolve qualifies — a CMap-less
    /// font with nothing but an embedded program has no tier available to
    /// consult, so walking it byte-by-byte in the no-CMap path
    /// (`emitShowSimpleFont`) would be pure overhead. With Tier 4 on, a
    /// usable embedded font program also qualifies.
    ///
    /// "Names something resolvable", not merely "has a `/Differences`":
    /// re-encoding an ordinary TEXT font through `/Differences` is completely
    /// routine, and such a font has nothing for any tier to say. Sending it
    /// down the byte path would only swap its whole-run string decoding for a
    /// byte-at-a-time one, for no classification gain.
    var canClassifyWithoutCMap: Bool {
        if let font, font.differences.values.contains(where: { name in
            GlyphNameTable.semantic(
                glyphName: name, allowingTextAmbiguousNames: acceptsTextAmbiguousNames,
            ) != nil
        }) { return true }
        return effectiveShapeMatching && ctFont != nil
    }

    /// - Parameters:
    ///   - codepoint: the Unicode scalar this glyph decoded to — Tier 1's key.
    ///   - characterCode: the raw code the content stream showed, in the
    ///     font's OWN encoding — Tier 2's key into `/Encoding /Differences`.
    ///     Pass nil unless the caller really has a character code: on the
    ///     CMap path the number in hand is a Unicode scalar, and the two key
    ///     spaces coincide only over ASCII, where a spurious `/Differences`
    ///     hit does the most damage (digits, punctuation).
    ///   - glyphID: the glyph ID in the embedded program — Tier 4's key.
    func classify(
        codepoint: UInt32, characterCode: UInt32?, glyphID: CGGlyph?,
    ) -> SMuFLSemantic {
        let key = CacheKey(
            codepoint: codepoint, characterCode: characterCode, glyphID: glyphID,
        )
        if let hit = cache[key] { return hit }
        let result = uncachedClassify(
            codepoint: codepoint, characterCode: characterCode, glyphID: glyphID,
        )
        cache[key] = result
        return result
    }

    private func uncachedClassify(
        codepoint: UInt32, characterCode: UInt32?, glyphID: CGGlyph?,
    ) -> SMuFLSemantic {
        // Tier 1 — SMuFL PUA codepoint.
        if !disableSMuFLTier {
            let tier1 = PDFImporter.smuflSemantic(codepoint: codepoint)
            if case .unknown = tier1 {} else { return tier1 }
        }

        // Tier 2 — glyph name.
        if let characterCode, let name = font?.differences[characterCode],
           let tier2 = GlyphNameTable.semantic(
               glyphName: name, allowingTextAmbiguousNames: acceptsTextAmbiguousNames,
           )
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
        guard bestDistance <= shapeAcceptanceThreshold, let best else { return nil }
        return best
    }

    // A `disambiguate(_:)` hook used to sit here, forcing every whole/half
    // rest verdict to `.rest(.whole)`. `restWhole` (U+E4E3) and `restHalf`
    // (U+E4E4) are the same 282×144 rectangle in Bravura, differing only by a
    // 133-unit vertical offset, and `normalizedBitmap` centres the bounding
    // box — so their descriptors were byte-identical, margin 0.0000, and the
    // verdict fell out of exemplar ORDER. Guessing `.whole` was the
    // low-regret choice at the time.
    //
    // `ShapeDescriptor.emBottom` removed the ambiguity: the whole rest hangs
    // BELOW its line and the half rest sits ABOVE it, which is a 0.5-space
    // difference every SMuFL font agrees on (Bravura -0.54/-0.01, Leland
    // -0.52/-0.02, MScore -0.62/0.00). Measured on the corpus, dropping the
    // forced guess raised Tier-4 glyph agreement on every score with no
    // regression (98.2→98.9, 98.1→98.6, 99.1→99.7, 98.1→99.0, 96.5→98.1,
    // 99.3→99.6) and left every score-level pitch% / dur% unchanged.

    /// Outlines are reached by RAW GLYPH ID only.
    ///
    /// A font subsetted into a PDF is measured NOT to preserve its
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
