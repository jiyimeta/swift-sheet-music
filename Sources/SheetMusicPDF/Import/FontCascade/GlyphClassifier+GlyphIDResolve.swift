#if canImport(CoreGraphics)
    import CoreGraphics
    import CoreText
#endif
import Foundation

/// Resolving a SIMPLE FONT's character code to a glyph ID in its embedded
/// program — the step that stood between real legacy-font PDFs and Tier 4.
extension GlyphClassifier {
    /// Map a 1-byte character code from a simple font's show operand to the
    /// glyph ID its outline lives under, or nil when nothing resolves.
    ///
    /// The byte is NOT the glyph ID. Measured on real Finale output: its
    /// music font (Kousaku) is subsetted to 16 glyphs and shows codes like
    /// 207, 206, 250, 228 — all far outside that range, so
    /// `CTFontCreatePathForGlyph` returned nil for every one of ~27,700
    /// occurrences and the score imported with zero notes. The subset DOES
    /// keep a Unicode cmap (15 of its 16 glyphs reachable) and the font dict
    /// declares `/Encoding /MacRomanEncoding`, so the byte reaches its
    /// outline by being decoded to a scalar first: 0xCF → U+0153 → glyph 12.
    ///
    /// Every strategy below ends in a lookup through the FONT'S OWN cmap, so
    /// a strategy that does not apply fails rather than resolving something
    /// wrong. Two plausible-looking strategies are deliberately absent:
    ///
    /// - Glyph NAME → `CTFontGetGlyphWithName`. Measured 0 for
    ///   `noteheadBlack` against the full, unsubsetted Bravura.otf, whose
    ///   CFF charset certainly carries that name — the name table is not
    ///   reachable through a `CTFontCreateWithGraphicsFont` font here.
    ///   Nothing is lost: a code `/Differences` names is already answered by
    ///   Tier 2, which never needed the glyph ID.
    /// - Identity (code IS the glyph ID). It cannot fail to "resolve": every
    ///   in-range code lands on SOME glyph, so it converts "this code is not
    ///   in the subset" into a confident wrong answer. Measured doing exactly
    ///   that — code 0x41 against Bravura, which has no `A`, came back as
    ///   glyph 65, an unrelated outline Tier 4 would then have named.
    ///
    ///   IMPLEMENTED, MEASURED AND REJECTED a second time (2026-07-28), this
    ///   time gated exactly as an earlier revision of this comment proposed:
    ///   allowed only for a font whose cmap answers NO code at all. The file
    ///   that motivated it, `TheHomeForYou_standard_A4.pdf` (printed through a
    ///   Windows PostScript driver; CFF subsets `TT9DDo00`… with no
    ///   `/Encoding`, no `/Differences`, no `/ToUnicode` and no usable cmap),
    ///   went from 0 notes to 340 — but the classification was fabricated:
    ///   1836 accidental flats out of 3401 glyphs, 615 clefs in 113 measures,
    ///   and NO black noteheads at all. A CFF subset re-indexes its glyphs, so
    ///   identity lands on real outlines that belong to other characters, and
    ///   Tier 4 names them confidently. The gate cannot fix that; identity is
    ///   wrong for this font class, not merely risky.
    ///
    ///   The correct route for such a font is its CFF's own built-in Encoding
    ///   (code → glyph index, in the font program's Top DICT), which CoreText
    ///   does not expose — it would have to be parsed out of `font.program`.
    ///   That, not identity, is what a future round should try.
    func resolveGlyphID(code: UInt32) -> CGGlyph? {
        if let hit = glyphIDCache[code] { return hit }
        let resolved = uncachedResolveGlyphID(code: code)
        glyphIDCache[code] = resolved
        return resolved
    }

    private func uncachedResolveGlyphID(code: UInt32) -> CGGlyph? {
        guard let ctFont else { return nil }

        // 1. The declared base encoding decodes the code to a scalar the
        //    font's cmap knows. This is the one real Finale / Sibelius
        //    output needs.
        let declared = font?.baseEncoding ?? ""
        if !declared.isEmpty {
            if let scalar = SimpleFontEncoding.scalar(code: code, baseEncoding: declared),
               let gid = glyphID(ctFont: ctFont, scalar: scalar)
            { return gid }
        } else {
            // 2. No declaration means "the font's built-in encoding", which
            //    this side cannot read. Try what producers actually emit; a
            //    wrong guess still has to hit this font's cmap, so it fails
            //    rather than resolving a wrong glyph.
            for candidate in SimpleFontEncoding.fallbackEncodings {
                guard let scalar = SimpleFontEncoding.scalar(code: code, baseEncoding: candidate),
                      let gid = glyphID(ctFont: ctFont, scalar: scalar) else { continue }
                return gid
            }
        }

        // 3. A SYMBOLIC TrueType font carries a (3, 0) cmap subtable whose
        //    keys are 0xF000 + code; CoreText surfaces those as Private Use
        //    Area scalars.
        if let scalar = Unicode.Scalar(0xF000 | (code & 0xFF)) {
            return glyphID(ctFont: ctFont, scalar: scalar)
        }
        return nil
    }

    /// The glyph this font's own cmap gives for `scalar`, or nil for
    /// `.notdef` / no mapping.
    private func glyphID(ctFont: CTFont, scalar: Unicode.Scalar) -> CGGlyph? {
        var units = Array(String(scalar).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: units.count)
        guard CTFontGetGlyphsForCharacters(ctFont, &units, &glyphs, units.count),
              let gid = glyphs.first, gid != 0 else { return nil }
        return gid
    }
}
