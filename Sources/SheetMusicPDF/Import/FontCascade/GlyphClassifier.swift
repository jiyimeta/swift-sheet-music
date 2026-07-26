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
    /// Enables Tier 4 (outline shape matching). **Default false** — see
    /// `PDFImportOptions.enableShapeMatching`. At the placeholder
    /// `shapeAcceptanceThreshold`, Tier 4 matches essentially every glyph
    /// outline from ANY embedded font — including a lyrics/text font like
    /// Hiragino or Edwin, which was never meant to reach Tier 4 at all — to
    /// some Bravura exemplar: measured on ギブス.pdf, 0 of 4254 glyphs were
    /// left `.unknown` and lyric recall collapsed from 92% to 0%. It stays
    /// off until Task 14 has both a measured threshold and a per-font gate
    /// deciding whether a font is plausibly a music font in the first place.
    private let enableShapeMatching: Bool
    /// TESTING ONLY. Suppresses Tier 1 (SMuFL codepoint) so the cascade falls
    /// through to Tier 2 / Tier 4 for measurement against Tier 1's
    /// known-correct answer. See `PDFImportOptions.disableSMuFLCodepointTier`.
    private let disableSMuFLTier: Bool
    private lazy var ctFont: CTFont? = {
        guard let program = font?.program, let kind = font?.programKind
        else { return nil }
        return makeCTFont(program: program, kind: kind)
    }()

    private var cache: [UInt32: SMuFLSemantic] = [:]

    /// Tier-4 acceptance threshold. A nearest neighbor farther than this is
    /// reported `.unknown` rather than guessed. STARTING VALUE — replace with
    /// the figure measured by the Task 13 ablation and record it here.
    /// Inert while `enableShapeMatching` is false (the default).
    nonisolated(unsafe) static var shapeAcceptanceThreshold = 0.45

    init(
        font: PDFImporter.EmbeddedFont?, enableShapeMatching: Bool = false,
        disableSMuFLTier: Bool = false,
    ) {
        self.font = font
        self.enableShapeMatching = enableShapeMatching
        self.disableSMuFLTier = disableSMuFLTier
    }

    /// True when this font can be classified without a `/ToUnicode` CMap.
    /// With Tier 4 off (the default), only a non-empty `/Differences` map
    /// (Tier 2) qualifies — a CMap-less font with nothing but an embedded
    /// program has no tier available to consult, so walking it byte-by-byte
    /// in the no-CMap path (`emitShowSimpleFont`) would be pure overhead.
    /// With Tier 4 on, a usable embedded font program also qualifies.
    var canClassifyWithoutCMap: Bool {
        if let font, !font.differences.isEmpty { return true }
        return enableShapeMatching && ctFont != nil
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

        // Tier 4 — outline shape match. Off by default; see
        // `enableShapeMatching`'s doc comment.
        if enableShapeMatching,
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
