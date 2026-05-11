// swiftlint:disable function_body_length file_length
import CoreText
import QuartzCore
import SheetMusicCore
import SheetMusicLayout

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

@available(macOS 15.0, iOS 16.0, *)
extension ScoreLayerBuilder {
    // MARK: - Path flipping

    /// Convert a path from LayoutEngine's Y-down coords to the host
    /// layer's native orientation.  On macOS we flip around the given
    /// height; on iOS paths pass through unchanged.
    static func flipForPlatform(
        _ path: CGPath, height: CGFloat,
    ) -> CGPath {
        #if os(macOS)
            // (x, y) → (x, height - y).  Direct matrix construction
            // (avoids CGAffineTransform's chained API which
            // post-multiplies operations in the transformed coord frame
            // rather than the outer frame — an easy trap).
            var t = CGAffineTransform(
                a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height,
            )
            return path.copy(using: &t) ?? path
        #else
            return path
        #endif
    }

    // MARK: - Shape-layer helpers

    private static func makeShapeLayer() -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.masksToBounds = false
        return layer
    }

    static func strokeLayer(
        path: CGPath,
        height: CGFloat,
        lineWidth: CGFloat,
        color: CGColor = inkColor,
        dashPattern: [NSNumber]? = nil,
    ) -> CAShapeLayer {
        let layer = makeShapeLayer()
        layer.path = flipForPlatform(path, height: height)
        layer.strokeColor = color
        layer.fillColor = nil
        layer.lineWidth = lineWidth
        if let dash = dashPattern {
            layer.lineDashPattern = dash
        }
        return layer
    }

    static func fillLayer(
        path: CGPath,
        height: CGFloat,
        color: CGColor = inkColor,
    ) -> CAShapeLayer {
        let layer = makeShapeLayer()
        layer.path = flipForPlatform(path, height: height)
        layer.fillColor = color
        return layer
    }

    // MARK: - Font caches

    private nonisolated(unsafe) static var cachedBravura: CTFont?
    private nonisolated(unsafe) static var cachedBravuraSize: CGFloat = 0

    static func bravuraFont(size: CGFloat) -> CTFont {
        if let font = cachedBravura, cachedBravuraSize == size {
            return font
        }
        _ = BravuraFont.register
        let font = CTFontCreateWithName(
            BravuraFont.familyName as CFString, size, nil,
        )
        cachedBravura = font
        cachedBravuraSize = size
        return font
    }

    private nonisolated(unsafe) static var cachedLyricFont: CTFont?
    private nonisolated(unsafe) static var cachedLyricFontSize: CGFloat = 0

    /// System font at regular weight, sized for lyrics. Cached
    /// because `CTFontCreate` is non-trivial in tight render
    /// loops.
    static func lyricFont(size: CGFloat) -> CTFont {
        if let f = cachedLyricFont, cachedLyricFontSize == size {
            return f
        }
        #if os(macOS)
            let font = NSFont.systemFont(
                ofSize: size, weight: .regular,
            ) as CTFont
        #else
            let font = UIFont.systemFont(
                ofSize: size, weight: .regular,
            ) as CTFont
        #endif
        cachedLyricFont = font
        cachedLyricFontSize = size
        return font
    }

    private nonisolated(unsafe) static var cachedSystemFont: CTFont?
    private nonisolated(unsafe) static var cachedSystemKey:
        (size: CGFloat, italic: Bool) = (0, false)

    static func systemFont(
        size: CGFloat, italic: Bool,
    ) -> CTFont {
        if let font = cachedSystemFont,
           cachedSystemKey == (size, italic)
        {
            return font
        }
        #if os(macOS)
            var nsfont = NSFont.systemFont(ofSize: size, weight: .semibold)
            if italic,
               let italicNs = NSFont(
                   descriptor: nsfont.fontDescriptor
                       .withSymbolicTraits(.italic),
                   size: size,
               )
            {
                nsfont = italicNs
            }
            let font = nsfont as CTFont
        #else
            var uifont = UIFont.systemFont(ofSize: size, weight: .semibold)
            if italic,
               let descriptor = uifont.fontDescriptor
                   .withSymbolicTraits(.traitItalic),
                   let italicUi = UIFont(descriptor: descriptor, size: size)
                   as UIFont?
            {
                uifont = italicUi
            }
            let font = uifont as CTFont
        #endif
        cachedSystemFont = font
        cachedSystemKey = (size, italic)
        return font
    }

    // MARK: - Glyph layer (Bravura SMuFL)

    private static func glyphPath(
        character: Character, font: CTFont,
    ) -> CGPath? {
        let uniChars = Array(String(character).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: uniChars.count)
        guard CTFontGetGlyphsForCharacters(
            font, uniChars, &glyphs, uniChars.count,
        ),
            let glyph = glyphs.first
        else { return nil }
        var transform = CGAffineTransform.identity
        return CTFontCreatePathForGlyph(font, glyph, &transform)
    }

    /// Build a CAShapeLayer containing a single SMuFL glyph whose
    /// UnitPoint `anchor` lands at `origin` in LayoutEngine Y-down
    /// coords.  Anchor semantics match SwiftUI's `Text`/`draw(at:
    /// anchor:)`: the anchor is in **text bounds** space (font
    /// ascent + descent for Y, path bbox width for X), not the
    /// path's ink bbox.  This preserves the historical positioning
    /// from the Canvas-based renderer — flags, dynamics, tempo text,
    /// etc. land on the stem tip / staff reference line.
    static func glyphLayer(
        _ ch: Character,
        at origin: CGPoint,
        size: CGFloat,
        anchor: CGPoint = CGPoint(x: 0.5, y: 0.5),
        rotation: CGFloat = 0,
        color: CGColor = inkColor,
        height: CGFloat,
    ) -> CAShapeLayer? {
        let font = bravuraFont(size: size)
        guard let path = glyphPath(character: ch, font: font) else {
            return nil
        }
        let bbox = path.boundingBoxOfPath
        var t = textAnchoringTransform(
            bbox: bbox, font: font, origin: origin, anchor: anchor,
        )
        if rotation != 0 {
            // Rotate around `origin` (post-anchoring): translate origin
            // to (0,0), rotate, translate back. Used by arpeggio so the
            // SMuFL horizontal wiggle becomes a vertical segment.
            t = t.concatenating(
                CGAffineTransform(translationX: -origin.x, y: -origin.y),
            )
            .concatenating(CGAffineTransform(rotationAngle: rotation))
            .concatenating(
                CGAffineTransform(translationX: origin.x, y: origin.y),
            )
        }
        var transformMut = t
        guard let transformed = path.copy(using: &transformMut) else {
            return nil
        }
        return fillLayer(
            path: transformed, height: height, color: color,
        )
    }

    /// Matrix that maps a CT Y-up path to Y-down with its
    /// SwiftUI-style text-bounds `anchor` point at `origin`.  The
    /// transform is direct rather than chained to avoid
    /// CGAffineTransform's post-multiplication surprise.
    ///
    /// Derivation:
    ///   A_CT = (bbox.minX + ax·w,  ascent - ay·(ascent + descent))
    ///   T(P) = scale(1, -1) · (P - A_CT) + origin
    ///        = (P.x - A_CT.x + origin.x, -P.y + A_CT.y + origin.y)
    ///   ⇒ (a, b, c, d, tx, ty) = (1, 0, 0, -1,
    ///                             origin.x - A_CT.x,
    ///                             origin.y + A_CT.y)
    private static func textAnchoringTransform(
        bbox: CGRect, font: CTFont,
        origin: CGPoint, anchor: CGPoint,
    ) -> CGAffineTransform {
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let aCTx = bbox.minX + anchor.x * bbox.width
        let aCTy = ascent - anchor.y * (ascent + descent)
        return CGAffineTransform(
            a: 1, b: 0, c: 0, d: -1,
            tx: origin.x - aCTx,
            ty: origin.y + aCTy,
        )
    }

    // MARK: - Text layer (system font, via path for vector quality)

    private static func textPath(
        _ text: String, font: CTFont,
    ) -> CGPath? {
        // Split on `\n` so multi-line `<StaffText>` payloads (which
        // commonly contain literal newlines like
        // "アタック強め\nクレッシェンドなし") render as stacked
        // lines instead of being collapsed onto one CTLine. Each
        // line goes below the previous in typography coords (y-up),
        // so we shift by `-i * lineHeight`.
        let lines = text.components(separatedBy: "\n")
        if lines.count <= 1 {
            return textPathSingleLine(text, font: font)
        }
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)
        let lineHeight = ascent + descent + leading
        let composite = CGMutablePath()
        for (i, line) in lines.enumerated() {
            guard let linePath = textPathSingleLine(
                line, font: font,
            ) else { continue }
            var t = CGAffineTransform(
                translationX: 0,
                y: -CGFloat(i) * lineHeight,
            )
            composite.addPath(linePath, transform: t)
        }
        return composite.isEmpty ? nil : composite
    }

    private static func textPathSingleLine(
        _ text: String, font: CTFont,
    ) -> CGPath? {
        let attr = NSAttributedString(
            string: text, attributes: [.font: font],
        )
        let line = CTLineCreateWithAttributedString(attr)
        let composite = CGMutablePath()

        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else {
            return nil
        }
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            let range = CFRange(location: 0, length: count)
            CTRunGetGlyphs(run, range, &glyphs)
            CTRunGetPositions(run, range, &positions)

            let runFont: CTFont
            if let attrs = CTRunGetAttributes(run)
                as? [String: Any],
                let runFontValue = attrs[
                    kCTFontAttributeName as String,
                ]
            {
                runFont = unsafeBitCast(
                    runFontValue as AnyObject, to: CTFont.self,
                )
            } else {
                runFont = font
            }

            for i in 0 ..< count {
                var t = CGAffineTransform(
                    translationX: positions[i].x,
                    y: positions[i].y,
                )
                if let gPath = CTFontCreatePathForGlyph(
                    runFont, glyphs[i], &t,
                ) {
                    composite.addPath(gPath)
                }
            }
        }
        return composite.isEmpty ? nil : composite
    }

    /// Legacy text-layer "kind" knob, kept for renderers that
    /// haven't yet been migrated to `ResolvedTextStyle`. New code
    /// should pass an explicit `font:` (a `CTFont` derived from a
    /// `TextStyleType`) and ignore this enum.
    enum TextLayerKind { case expression, lyrics }

    static func textLayer(
        text: String,
        at origin: CGPoint,
        size: CGFloat,
        italic: Bool,
        anchor: CGPoint = CGPoint(x: 0, y: 0.5),
        rotation: CGFloat = 0,
        color: CGColor = inkColor,
        kind: TextLayerKind = .expression,
        font explicitFont: CTFont? = nil,
        height: CGFloat,
    ) -> CAShapeLayer? {
        guard !text.isEmpty else { return nil }
        let font: CTFont
        if let explicitFont {
            font = explicitFont
        } else {
            switch kind {
            case .expression:
                font = systemFont(size: size, italic: italic)
            case .lyrics:
                // Fallback used by older call sites; the in-scope
                // text styles (dynamics, tempo, rehearsalMark,
                // staffText, lyrics, pedal) now go through
                // `ResolvedTextStyle` and pass an explicit
                // Edwin-based CTFont via the `font:` parameter.
                font = lyricFont(size: size)
            }
        }
        guard let path = textPath(text, font: font) else { return nil }
        let bbox = path.boundingBoxOfPath

        // Use font-metric-based anchoring (same as glyphLayer) so
        // SwiftUI-style `.leading`, `.center`, etc. all land at the
        // same visual positions the Canvas-based renderer used.  For
        // rotation we compose manually: final = T_origin · R · T_anchor
        // where T_anchor = scale(1,-1) translating A_CT → (0, 0).
        //
        // For multi-line strings, the total height grows with line
        // count: top of the first line still sits at `ascent`, but
        // the bottom is `(lineCount - 1) * lineHeight + descent`
        // below baseline. Computing `totalHeight` here keeps the
        // bottom-leading anchor (and friends) on the bottom of the
        // LAST line, not the first.
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let leading = CTFontGetLeading(font)
        let lineHeight = ascent + descent + leading
        let lineCount = text.components(separatedBy: "\n").count
        let totalHeight = ascent + descent
            + CGFloat(max(0, lineCount - 1)) * lineHeight
        let aCTx = bbox.minX + anchor.x * bbox.width
        let aCTy = ascent - anchor.y * totalHeight

        if rotation == 0 {
            var t = CGAffineTransform(
                a: 1, b: 0, c: 0, d: -1,
                tx: origin.x - aCTx,
                ty: origin.y + aCTy,
            )
            guard let transformed = path.copy(using: &t) else {
                return nil
            }
            return fillLayer(
                path: transformed, height: height, color: color,
            )
        }

        // Rotation path: build T_origin · R · T_anchor explicitly by
        // hand-multiplying.  Let R = (c, s, -s, c, 0, 0) and
        // T_anchor = (1, 0, 0, -1, -aCTx, aCTy).  Then
        //   R · T_anchor = (c, s, s, -c, -c·aCTx - s·aCTy, -s·aCTx + c·aCTy)
        //   T_origin · (R · T_anchor) adds origin to the tx, ty.
        let c = cos(rotation)
        let s = sin(rotation)
        var t = CGAffineTransform(
            a: c, b: s, c: s, d: -c,
            tx: origin.x - c * aCTx - s * aCTy,
            ty: origin.y - s * aCTx + c * aCTy,
        )
        guard let transformed = path.copy(using: &t) else { return nil }
        return fillLayer(
            path: transformed, height: height, color: color,
        )
    }
}
