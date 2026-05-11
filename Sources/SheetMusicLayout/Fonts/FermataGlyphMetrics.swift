import CoreGraphics
import CoreText
import Foundation

/// Per-glyph offsets describing where the visible glyph sits relative
/// to `origin.y` when `Text(glyph)` is drawn with anchor `.center`
/// (the convention used by `GraphicsContext.drawGlyph` and
/// `ScoreLayerBuilder.glyphLayer`). Positive Y = lower on screen
/// (CG screen-Y-down).
///
/// All values are at `fontSize = 4` (i.e. 1 sp = 1 unit), so callers
/// scale by their own `metrics.sp`.
@available(macOS 15.0, iOS 16.0, *)
public struct FermataGlyphOffsets: Sendable {
    /// Screen-Y of the visible glyph's BOTTOM minus `origin.y`,
    /// measured in sp-units. Positive = glyph bottom is below origin.
    public let bottomOffset: CGFloat
    /// Screen-Y of the visible glyph's TOP minus `origin.y`, measured
    /// in sp-units. Positive = glyph top is below origin.
    public let topOffset: CGFloat
}

/// Runtime-measured offsets for the SMuFL fermata glyphs in Bravura.
///
/// The layout engine uses these to position the fermata `origin.y`
/// such that the visible glyph EDGE — not its typographic bbox —
/// clears the chord skyline by a known gap. Drawing fermata via
/// SwiftUI `Text` with anchor `.center` aligns the font's typographic
/// bbox (ascent + descent) to `origin.y`; Bravura's ascent/descent
/// are highly asymmetric, so the visible glyph sits well off-centre
/// from `origin.y`. Use these measured offsets instead of guessing.
///
/// Mirrors `BraceMetrics`'s runtime CTFont measurement pattern so the
/// layout target stays self-contained (no dependency on the renderer
/// module).
@available(macOS 15.0, iOS 16.0, *)
public enum FermataGlyphMetrics {
    /// fermataAbove (U+E4C0).
    public static var above: FermataGlyphOffsets {
        offsets(for: 0xE4C0)
    }

    /// fermataBelow (U+E4C1).
    public static var below: FermataGlyphOffsets {
        offsets(for: 0xE4C1)
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: [UInt16: FermataGlyphOffsets] = [:]

    private static func offsets(for codepoint: UInt16) -> FermataGlyphOffsets {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[codepoint] { return cached }
        let measured = measure(codepoint: codepoint)
        cache[codepoint] = measured
        return measured
    }

    private static func measure(codepoint: UInt16) -> FermataGlyphOffsets {
        _ = BravuraFont.register
        // sp = 1 → fontSize = 4 (Bravura's 1 em = 4 sp). Cached
        // values are then in sp-units; callers scale by their own sp.
        let font = CTFontCreateWithName(
            BravuraFont.familyName as CFString, 4, nil,
        )
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        // Anchor .center puts the text view's typographic CENTRE at
        // origin.y. Text view height = ascent + descent. The baseline
        // therefore sits `(ascent - descent) / 2` BELOW origin in
        // screen-Y-down coords.
        let baselineFromCenter = (ascent - descent) / 2
        var unichars: [UniChar] = [codepoint]
        var glyphs: [CGGlyph] = [0]
        guard CTFontGetGlyphsForCharacters(
            font, &unichars, &glyphs, 1,
        ), glyphs[0] != 0,
        let path = CTFontCreatePathForGlyph(font, glyphs[0], nil)
        else {
            // Defensive fallback if the glyph isn't in the font:
            // assume a centred 0.7-sp tall glyph at the baseline.
            return FermataGlyphOffsets(
                bottomOffset: baselineFromCenter,
                topOffset: baselineFromCenter - 0.7,
            )
        }
        let bbox = path.boundingBox
        // bbox is in font-Y-up coords with baseline at y=0.
        //   Screen-Y of glyph bottom = baseline - bbox.minY
        //   Screen-Y of glyph top    = baseline - bbox.maxY
        return FermataGlyphOffsets(
            bottomOffset: baselineFromCenter - bbox.minY,
            topOffset: baselineFromCenter - bbox.maxY,
        )
    }
}
