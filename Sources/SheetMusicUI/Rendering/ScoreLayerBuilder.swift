import CoreText
import QuartzCore
import SheetMusicCore

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Builds a `CALayer` tree from a `LayoutSystem`.
///
/// Each element of the score becomes its own `CAShapeLayer` (or small
/// group of layers) with a resolution-independent `CGPath`, so the
/// content stays sharp at any zoom level — unlike the older
/// `Canvas`-based renderer which rasterised once at layout size.
///
/// Glyphs (Bravura SMuFL + system-font expression text) are rendered
/// via paths extracted with `CTFontCreatePathForGlyph`, so they are
/// genuine vectors at every zoom.
///
/// LayoutEngine emits Y-down coordinates (y increases downward from
/// the system's top).  On macOS, CALayer uses Y-up by default, so we
/// flip every path's Y at construction time via a helper
/// (`flipForPlatform`).  On iOS, `UIView.layer` is already Y-down and
/// no flip is applied.
@available(macOS 15.0, iOS 16.0, *)
public enum ScoreLayerBuilder {
    /// Ink colour for all strokes / fills.  Matches the prior
    /// `.environment(\.colorScheme, .light)` + `.color(.primary)`
    /// combination — always black on white.
    static let inkColor: CGColor = CGColor(gray: 0, alpha: 1)

    /// Convert MuseScore's RGBA score colour into a `CGColor`. Used
    /// for `.staffText` (and any future author-coloured element) so
    /// the renderer can honour `<color>` attributes from `.mscx`.
    static func scoreColorToCGColor(
        _ color: ScoreColor
    ) -> CGColor {
        CGColor(
            red: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: CGFloat(color.alpha) / 255)
    }

    // MARK: - Entry point

    public static func buildSystem(
        _ system: LayoutSystem,
        metrics: StaffMetrics
    ) -> CALayer {
        buildSystemWithItems(system, metrics: metrics).root
    }

    /// Builds the base layer tree and returns both the root CALayer
    /// and a dictionary mapping each selectable `ScoreItemID` to the
    /// CAShapeLayers that must be re-tinted when the selection
    /// changes.
    ///
    /// The tree is always drawn in `inkColor` — selection colouring
    /// is applied afterwards via `applySelection(...)` so that a
    /// selection change does not force a full layer rebuild.
    static func buildSystemWithItems(
        _ system: LayoutSystem,
        metrics: StaffMetrics
    ) -> (root: CALayer, items: [ScoreItemID: [CAShapeLayer]]) {
        let root = CALayer()
        let height = system.size.height + 1
        root.frame = CGRect(
            origin: .zero,
            size: CGSize(
                width: system.size.width,
                height: height))
        root.masksToBounds = false
        root.backgroundColor = CGColor(gray: 1, alpha: 1)

        drawStaves(
            system: system, metrics: metrics,
            height: height, into: root)
        drawBracket(
            system: system, metrics: metrics,
            height: height, into: root)
        drawPartLabels(
            system: system, metrics: metrics,
            height: height, into: root)

        var ctx = BuildContext()
        for measure in system.measures {
            let base = CGPoint(x: measure.origin.x, y: measure.origin.y)
            for element in measure.elements {
                drawElement(
                    element, base: base,
                    metrics: metrics, height: height,
                    context: &ctx, into: root)
            }
            for el in measure.markers {
                drawElement(
                    el, base: base,
                    metrics: metrics, height: height,
                    context: &ctx, into: root)
            }
            for el in measure.jumps {
                drawElement(
                    el, base: base,
                    metrics: metrics, height: height,
                    context: &ctx, into: root)
            }
        }
        for el in system.spanners {
            drawElement(
                el, base: .zero,
                metrics: metrics, height: height,
                context: &ctx, into: root)
        }
        return (root, ctx.items)
    }

    /// Context threaded through draw calls to collect the layers that
    /// the selection renderer will later re-tint.
    struct BuildContext {
        var items: [ScoreItemID: [CAShapeLayer]] = [:]

        mutating func attach(
            _ layer: CAShapeLayer, to id: ScoreItemID
        ) {
            items[id, default: []].append(layer)
        }
    }

    /// Re-tints the already-built `items` so they reflect
    /// `newSelection`. Layers previously tinted for `previousSelection`
    /// are reset to `inkColor`; layers for the new selection pick up
    /// their voice colour.
    ///
    /// Work is O(|previous ∪ new|), not O(score size), so selection
    /// changes stay cheap regardless of how large the score is.
    static func applySelection(
        items: [ScoreItemID: [CAShapeLayer]],
        previousSelection: SelectionRenderState,
        newSelection: SelectionRenderState
    ) {
        let toReset = previousSelection.selectedIDs
            .subtracting(newSelection.selectedIDs)
        for id in toReset {
            guard let layers = items[id] else { continue }
            for layer in layers { layer.fillColor = inkColor }
        }
        for id in newSelection.selectedIDs {
            guard let layers = items[id] else { continue }
            let color = newSelection.voiceColors[id.voiceIndex] ?? inkColor
            for layer in layers { layer.fillColor = color }
        }
    }

    // MARK: - Path flipping

    /// Convert a path from LayoutEngine's Y-down coords to the host
    /// layer's native orientation.  On macOS we flip around the given
    /// height; on iOS paths pass through unchanged.
    private static func flipForPlatform(
        _ path: CGPath, height: CGFloat
    ) -> CGPath {
        #if os(macOS)
        // (x, y) → (x, height - y).  Direct matrix construction
        // (avoids CGAffineTransform's chained API which
        // post-multiplies operations in the transformed coord frame
        // rather than the outer frame — an easy trap).
        var t = CGAffineTransform(
            a: 1, b: 0, c: 0, d: -1, tx: 0, ty: height)
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

    private static func strokeLayer(
        path: CGPath,
        height: CGFloat,
        lineWidth: CGFloat,
        color: CGColor = inkColor,
        dashPattern: [NSNumber]? = nil
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

    private static func fillLayer(
        path: CGPath,
        height: CGFloat,
        color: CGColor = inkColor
    ) -> CAShapeLayer {
        let layer = makeShapeLayer()
        layer.path = flipForPlatform(path, height: height)
        layer.fillColor = color
        return layer
    }

    // MARK: - Font caches

    private nonisolated(unsafe) static var cachedBravura: CTFont?
    private nonisolated(unsafe) static var cachedBravuraSize: CGFloat = 0

    private static func bravuraFont(size: CGFloat) -> CTFont {
        if let font = cachedBravura, cachedBravuraSize == size {
            return font
        }
        _ = BravuraFont.register
        let font = CTFontCreateWithName(
            BravuraFont.familyName as CFString, size, nil)
        cachedBravura = font
        cachedBravuraSize = size
        return font
    }

    private nonisolated(unsafe) static var cachedLyricFont: CTFont?
    private nonisolated(unsafe) static var cachedLyricFontSize: CGFloat = 0

    /// System font at regular weight, sized for lyrics. Cached
    /// because `CTFontCreate` is non-trivial in tight render
    /// loops.
    private static func lyricFont(size: CGFloat) -> CTFont {
        if let f = cachedLyricFont, cachedLyricFontSize == size {
            return f
        }
        #if os(macOS)
        let font = NSFont.systemFont(
            ofSize: size, weight: .regular) as CTFont
        #else
        let font = UIFont.systemFont(
            ofSize: size, weight: .regular) as CTFont
        #endif
        cachedLyricFont = font
        cachedLyricFontSize = size
        return font
    }

    private nonisolated(unsafe) static var cachedSystemFont: CTFont?
    private nonisolated(unsafe) static var cachedSystemKey:
        (size: CGFloat, italic: Bool) = (0, false)

    private static func systemFont(
        size: CGFloat, italic: Bool
    ) -> CTFont {
        if let font = cachedSystemFont,
           cachedSystemKey == (size, italic) {
            return font
        }
        #if os(macOS)
        var nsfont = NSFont.systemFont(ofSize: size, weight: .semibold)
        if italic,
           let italicNs = NSFont(
                descriptor: nsfont.fontDescriptor
                    .withSymbolicTraits(.italic),
                size: size) {
            nsfont = italicNs
        }
        let font = nsfont as CTFont
        #else
        var uifont = UIFont.systemFont(ofSize: size, weight: .semibold)
        if italic,
           let descriptor = uifont.fontDescriptor
                .withSymbolicTraits(.traitItalic),
           let italicUi = UIFont(descriptor: descriptor, size: size)
                as UIFont? {
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
        character: Character, font: CTFont
    ) -> CGPath? {
        let uniChars = Array(String(character).utf16)
        var glyphs = [CGGlyph](repeating: 0, count: uniChars.count)
        guard CTFontGetGlyphsForCharacters(
            font, uniChars, &glyphs, uniChars.count),
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
    private static func glyphLayer(
        _ ch: Character,
        at origin: CGPoint,
        size: CGFloat,
        anchor: CGPoint = CGPoint(x: 0.5, y: 0.5),
        color: CGColor = inkColor,
        height: CGFloat
    ) -> CAShapeLayer? {
        let font = bravuraFont(size: size)
        guard let path = glyphPath(character: ch, font: font) else {
            return nil
        }
        let bbox = path.boundingBoxOfPath
        let t = textAnchoringTransform(
            bbox: bbox, font: font, origin: origin, anchor: anchor)
        var transformMut = t
        guard let transformed = path.copy(using: &transformMut) else {
            return nil
        }
        return fillLayer(
            path: transformed, height: height, color: color)
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
        origin: CGPoint, anchor: CGPoint
    ) -> CGAffineTransform {
        let ascent = CTFontGetAscent(font)
        let descent = CTFontGetDescent(font)
        let aCTx = bbox.minX + anchor.x * bbox.width
        let aCTy = ascent - anchor.y * (ascent + descent)
        return CGAffineTransform(
            a: 1, b: 0, c: 0, d: -1,
            tx: origin.x - aCTx,
            ty: origin.y + aCTy)
    }

    // MARK: - Text layer (system font, via path for vector quality)

    private static func textPath(
        _ text: String, font: CTFont
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
                line, font: font) else { continue }
            var t = CGAffineTransform(
                translationX: 0,
                y: -CGFloat(i) * lineHeight)
            composite.addPath(linePath, transform: t)
        }
        return composite.isEmpty ? nil : composite
    }

    private static func textPathSingleLine(
        _ text: String, font: CTFont
    ) -> CGPath? {
        let attr = NSAttributedString(
            string: text, attributes: [.font: font])
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
                    kCTFontAttributeName as String] {
                runFont = unsafeBitCast(
                    runFontValue as AnyObject, to: CTFont.self)
            } else {
                runFont = font
            }

            for i in 0..<count {
                var t = CGAffineTransform(
                    translationX: positions[i].x,
                    y: positions[i].y)
                if let gPath = CTFontCreatePathForGlyph(
                    runFont, glyphs[i], &t) {
                    composite.addPath(gPath)
                }
            }
        }
        return composite.isEmpty ? nil : composite
    }

    /// Text-layer "kind" — picks the font family. MuseScore's
    /// engraving uses different fonts for chrome (system serif),
    /// dynamics / tempo (italic system), and lyrics (Edwin / Times
    /// at regular weight). We approximate Edwin with Times, which
    /// renders ~25 % narrower than the SF Pro semibold the rest
    /// of the score uses.
    enum TextLayerKind { case expression, lyrics }

    private static func textLayer(
        text: String,
        at origin: CGPoint,
        size: CGFloat,
        italic: Bool,
        anchor: CGPoint = CGPoint(x: 0, y: 0.5),
        rotation: CGFloat = 0,
        color: CGColor = inkColor,
        kind: TextLayerKind = .expression,
        height: CGFloat
    ) -> CAShapeLayer? {
        guard !text.isEmpty else { return nil }
        let font: CTFont
        switch kind {
        case .expression:
            font = systemFont(size: size, italic: italic)
        case .lyrics:
            // System font at regular weight — ~15 % narrower
            // than the semibold used for expression text, with
            // proper CJK fallback. See `drawLyricText` in
            // `GraphicsContext+Glyph.swift` for the matching
            // Canvas-side rendering and the font-choice
            // rationale.
            font = lyricFont(size: size)
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
                ty: origin.y + aCTy)
            guard let transformed = path.copy(using: &t) else {
                return nil
            }
            return fillLayer(
                path: transformed, height: height, color: color)
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
            ty: origin.y - s * aCTx + c * aCTy)
        guard let transformed = path.copy(using: &t) else { return nil }
        return fillLayer(
            path: transformed, height: height, color: color)
    }

    // MARK: - Staves, bracket, part labels

    private static func drawStaves(
        system: LayoutSystem,
        metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer
    ) {
        for origin in system.staffOrigins {
            let path = CGMutablePath()
            let width = system.size.width - origin.x
            for i in 0..<5 {
                let y = origin.y + CGFloat(i) * metrics.sp
                path.move(to: CGPoint(x: origin.x, y: y))
                path.addLine(
                    to: CGPoint(x: origin.x + width, y: y))
            }
            parent.addSublayer(strokeLayer(
                path: path,
                height: height,
                lineWidth: metrics.staffLineThickness))
        }
    }

    private static func drawBracket(
        system: LayoutSystem,
        metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer
    ) {
        guard system.staffOrigins.count >= 2,
              let top = system.staffOrigins.first,
              let bot = system.staffOrigins.last
        else { return }
        let x = top.x - metrics.sp * 0.5
        let topPt = CGPoint(x: x, y: top.y)
        let botPt = CGPoint(x: x, y: bot.y + metrics.staffHeight)

        let spine = CGMutablePath()
        spine.move(to: topPt)
        spine.addLine(to: botPt)
        parent.addSublayer(strokeLayer(
            path: spine,
            height: height,
            lineWidth: metrics.sp * 0.3))

        for point in [topPt, botPt] {
            let serif = CGMutablePath()
            serif.move(to: point)
            serif.addLine(to: CGPoint(
                x: point.x + metrics.sp * 0.8, y: point.y))
            parent.addSublayer(strokeLayer(
                path: serif,
                height: height,
                lineWidth: metrics.sp * 0.25))
        }
    }

    private static func drawPartLabels(
        system: LayoutSystem,
        metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer
    ) {
        for label in system.partLabels {
            guard !label.text.isEmpty else { continue }
            let origin = CGPoint(
                x: (system.staffOrigins.first?.x ?? 60) - metrics.sp,
                y: label.origin.y)
            if let layer = textLayer(
                text: label.text,
                at: origin,
                size: metrics.sp * 2.5,
                italic: false,
                anchor: CGPoint(x: 1, y: 0.5),
                height: height) {
                parent.addSublayer(layer)
            }
        }
    }

    // MARK: - Element dispatch

    private static func drawElement(
        _ element: LayoutElement,
        base: CGPoint,
        metrics: StaffMetrics,
        height: CGFloat,
        context: inout BuildContext,
        into parent: CALayer
    ) {
        func shift(_ p: CGPoint) -> CGPoint {
            CGPoint(x: base.x + p.x, y: base.y + p.y)
        }
        switch element {
        case .clef(let raw, let p):
            drawClef(
                rawType: raw, origin: shift(p),
                metrics: metrics, height: height, into: parent)
        case .keySignature(let s, let f, let p):
            drawKeySignature(
                sharps: s, flats: f, origin: shift(p),
                metrics: metrics, height: height, into: parent)
        case .timeSignature(let n, let d, let p):
            drawTimeSignature(
                numerator: n, denominator: d, origin: shift(p),
                metrics: metrics, height: height, into: parent)
        case .barLine(let s, let p):
            drawBarLine(
                subtype: s, origin: shift(p),
                metrics: metrics, height: height, into: parent)
        case let .rest(d, p, _, rid, hll):
            if let layer = drawRest(
                duration: d, origin: shift(p),
                hasLegerLine: hll,
                metrics: metrics, height: height, into: parent) {
                context.attach(layer, to: .rest(rid))
            }
        case .chord(let notes, let dur, let stem, let so,
                    _, _, let beamed, _):
            drawChord(
                notes: notes, duration: dur, stem: stem,
                stemOrigin: so, isBeamed: beamed,
                base: base,
                metrics: metrics, height: height,
                context: &context, into: parent)
        case .textMark(.dynamic, let text, let p):
            if let layer = textLayer(
                text: text, at: shift(p),
                size: metrics.sp * 2.5, italic: true,
                anchor: CGPoint(x: 0, y: 0.5),
                height: height) {
                parent.addSublayer(layer)
            }
        case .textMark(.tempo, let text, let p):
            if let layer = textLayer(
                text: text, at: shift(p),
                size: metrics.sp * 2.2, italic: false,
                anchor: CGPoint(x: 0, y: 0.5),
                height: height) {
                parent.addSublayer(layer)
            }
        case .textMark(.lyrics, let text, let p):
            if let layer = textLayer(
                text: text, at: shift(p),
                size: metrics.sp * 2.2, italic: false,
                anchor: CGPoint(x: 0.5, y: 0.5),
                kind: .lyrics,
                height: height) {
                parent.addSublayer(layer)
            }
        case .beam(let from, let to, let direction, let level):
            drawBeam(
                from: shift(from), to: shift(to),
                direction: direction, level: level,
                metrics: metrics, height: height, into: parent)
        case .fermata(let subtype, let p):
            drawFermata(
                subtype: subtype, origin: shift(p),
                metrics: metrics, height: height, into: parent)
        case .measureRepeat(let c, let p):
            drawMeasureRepeat(
                count: c, origin: shift(p),
                metrics: metrics, height: height, into: parent)
        case .arpeggioWiggle(let top, let bot, let sub):
            drawArpeggio(
                top: shift(top), bottom: shift(bot), subtype: sub,
                metrics: metrics, height: height, into: parent)
        case .spannerSegment(
            let kind, let from, let to, let cl, let cr, let text):
            drawSpanner(
                kind: kind, from: shift(from), to: shift(to),
                continuesLeft: cl, continuesRight: cr, text: text,
                metrics: metrics, height: height, into: parent)
        case .tieArc(let from, let to, let above):
            drawTieArc(
                from: shift(from), to: shift(to), above: above,
                metrics: metrics, height: height, into: parent)
        case .glissandoLine(let from, let to, let wavy, let text):
            drawGlissando(
                from: shift(from), to: shift(to), wavy: wavy,
                text: text,
                metrics: metrics, height: height, into: parent)
        case .tupletLabel(
            let from, let to, let text, let bracket, let above):
            drawTuplet(
                from: shift(from), to: shift(to),
                text: text, hasBracket: bracket, isAbove: above,
                metrics: metrics, height: height, into: parent)
        case .marker(let kind, let text, let p):
            drawMarker(
                kind: kind, text: text, origin: shift(p),
                metrics: metrics, height: height, into: parent)
        case .jump(let text, let p):
            if !text.isEmpty,
               let layer = textLayer(
                text: text, at: shift(p),
                size: metrics.sp * 2.5, italic: true,
                anchor: CGPoint(x: 0, y: 0.5),
                height: height) {
                parent.addSublayer(layer)
            }
        case .measureNumber(let text, let p):
            // Measure number at MuseScore's
            // `TextStyleType::DEFAULT` size (10 pt at 5 pt-spatium
            // ≈ 2 spatia → `sp * 2.0`), bottom-LEADING anchored so
            // the digits' LEFT edge lines up with `origin.x` — the
            // layout pins it to the bracket spine for inline use,
            // or to `keySigX` in the sticky pane.
            if !text.isEmpty,
               let layer = textLayer(
                text: text, at: shift(p),
                size: metrics.sp * 2.0, italic: false,
                anchor: CGPoint(x: 0, y: 1),
                height: height) {
                parent.addSublayer(layer)
            }
        case .staffText(let text, let p, let color, _):
            // Author-supplied staff/system text. Colour and offset
            // (already baked into `p` by placement) come from the
            // source `.mscx`. Bottom-leading anchor at `p` matches
            // the placement convention used for dynamics/tempo.
            if !text.isEmpty,
               let layer = textLayer(
                text: text, at: shift(p),
                size: metrics.sp * 2.2, italic: false,
                anchor: CGPoint(x: 0, y: 1),
                color: color.map(scoreColorToCGColor)
                    ?? Self.inkColor,
                height: height) {
                parent.addSublayer(layer)
            }
        case .staffName(let text, let p):
            // Staff name in the sticky pane: bottom-leading anchor
            // so the text sits ABOVE the staff with its left edge at
            // `origin.x` (which the layout sets to `keySigX`,
            // matching MuseScore's `clefLeftMargin + widthClef`).
            // Same `sp * 2.0` size as the measure number above it,
            // matching MuseScore's `TextStyleType::DEFAULT`. The
            // CALayer tree has `masksToBounds = false`, so a long
            // instrument name overflows the pane's white frame to
            // the right without forcing the panel itself to grow.
            if !text.isEmpty,
               let layer = textLayer(
                text: text, at: shift(p),
                size: metrics.sp * 2.0, italic: false,
                anchor: CGPoint(x: 0, y: 1),
                height: height) {
                parent.addSublayer(layer)
            }
        case .lyricsMelisma(let from, let to),
             .lyricHyphen(let from, let to):
            // Hyphens reuse the melisma rule's stroke (0.1 sp,
            // matching MuseScore's `lyricsDashLineThickness`); the
            // layout decides position and length per
            // `LyricsLayout::layoutDashes`.
            drawLyricsMelisma(
                from: shift(from), to: shift(to),
                metrics: metrics, height: height, into: parent)
        case .note:
            break
        }
    }

    // MARK: - Melisma

    private static func drawLyricsMelisma(
        from: CGPoint, to: CGPoint,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
    ) {
        let path = CGMutablePath()
        path.move(to: from)
        path.addLine(to: to)
        // MuseScore uses ~0.1 sp for the melisma rule (engraving
        // default `LYRICS_LINE_WIDTH`). That's a touch thinner than
        // a staff line — slim enough that the rule doesn't pull
        // visual weight from the noteheads above.
        parent.addSublayer(strokeLayer(
            path: path, height: height,
            lineWidth: metrics.sp * 0.1))
    }

    // MARK: - Clef

    private static func drawClef(
        rawType: String, origin: CGPoint,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
    ) {
        let clef = NotatedClef(rawType: rawType)
        let glyph: Character
        let yOffset: CGFloat
        switch clef {
        case .treble:     glyph = SMuFLGlyph.gClef;     yOffset = metrics.sp
        case .treble8va:  glyph = SMuFLGlyph.gClef8va;  yOffset = metrics.sp
        case .treble8vb:  glyph = SMuFLGlyph.gClef8vb;  yOffset = metrics.sp
        case .treble15ma: glyph = SMuFLGlyph.gClef15ma; yOffset = metrics.sp
        case .treble15mb: glyph = SMuFLGlyph.gClef15mb; yOffset = metrics.sp
        case .bass:       glyph = SMuFLGlyph.fClef;     yOffset = -metrics.sp
        case .bass8va:    glyph = SMuFLGlyph.fClef8va;  yOffset = -metrics.sp
        case .bass8vb:    glyph = SMuFLGlyph.fClef8vb;  yOffset = -metrics.sp
        case .alto, .tenor:  glyph = SMuFLGlyph.cClef;  yOffset = 0
        case .percussion:    glyph = SMuFLGlyph.percussionClef; yOffset = 0
        }
        if let layer = glyphLayer(
            glyph,
            at: CGPoint(x: origin.x, y: origin.y + yOffset),
            size: metrics.glyphFontSize,
            height: height) {
            parent.addSublayer(layer)
        }
    }

    // MARK: - Key signature

    private static let sharpSteps: [Int] = [4, 1, 5, 2, -1, 3, 0]
    private static let flatSteps:  [Int] = [0, 3, -1, 2, -2, 1, -3]

    private static func drawKeySignature(
        sharps: Int, flats: Int, origin: CGPoint,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
    ) {
        let count = max(0, sharps) + max(0, flats)
        guard count > 0 else { return }
        let isSharp = sharps > 0
        let glyph = isSharp
            ? SMuFLGlyph.accidentalSharp
            : SMuFLGlyph.accidentalFlat
        let steps = isSharp ? sharpSteps : flatSteps
        let advance = metrics.sp * 1.4
        for i in 0..<min(count, steps.count) {
            let step = steps[i]
            let x = origin.x + CGFloat(i) * advance
            let y = origin.y - CGFloat(step) * metrics.sp / 2
            if let layer = glyphLayer(
                glyph,
                at: CGPoint(x: x, y: y),
                size: metrics.glyphFontSize,
                height: height) {
                parent.addSublayer(layer)
            }
        }
    }

    // MARK: - Time signature

    private static func drawTimeSignature(
        numerator: Int, denominator: Int,
        origin: CGPoint, metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer
    ) {
        let numStr = String(numerator)
        let denStr = String(denominator)
        let digitAdvance = metrics.sp * 1.4
        let numWidth = CGFloat(numStr.count) * digitAdvance
        let denWidth = CGFloat(denStr.count) * digitAdvance
        let maxWidth = max(numWidth, denWidth)
        let numOffsetX = (maxWidth - numWidth) / 2
        let denOffsetX = (maxWidth - denWidth) / 2

        for (i, ch) in numStr.enumerated() {
            let digit = Int(String(ch)) ?? 0
            if let layer = glyphLayer(
                SMuFLGlyph.timeSigDigit(digit),
                at: CGPoint(
                    x: origin.x + numOffsetX
                        + CGFloat(i) * digitAdvance,
                    y: origin.y - metrics.sp),
                size: metrics.glyphFontSize,
                height: height) {
                parent.addSublayer(layer)
            }
        }
        for (i, ch) in denStr.enumerated() {
            let digit = Int(String(ch)) ?? 0
            if let layer = glyphLayer(
                SMuFLGlyph.timeSigDigit(digit),
                at: CGPoint(
                    x: origin.x + denOffsetX
                        + CGFloat(i) * digitAdvance,
                    y: origin.y + metrics.sp),
                size: metrics.glyphFontSize,
                height: height) {
                parent.addSublayer(layer)
            }
        }
    }

    // MARK: - Bar line

    private static func drawBarLine(
        subtype: String?, origin: CGPoint,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
    ) {
        let topY = origin.y - metrics.sp * 2
        let botY = origin.y + metrics.sp * 2
        func line(dx: CGFloat, width: CGFloat) {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: origin.x + dx, y: topY))
            path.addLine(to: CGPoint(x: origin.x + dx, y: botY))
            parent.addSublayer(strokeLayer(
                path: path, height: height, lineWidth: width))
        }
        switch subtype {
        case "double":
            line(dx: -metrics.sp * 0.3, width: metrics.sp * 0.15)
            line(dx: +metrics.sp * 0.3, width: metrics.sp * 0.15)
        case "end", "final":
            line(dx: 0, width: metrics.sp * 0.15)
            line(dx: +metrics.sp * 0.4, width: metrics.sp * 0.4)
        case "start-repeat":
            line(dx: 0, width: metrics.sp * 0.4)
            line(dx: +metrics.sp * 0.3, width: metrics.sp * 0.15)
            drawRepeatDots(
                origin: origin, xOffset: metrics.sp * 0.6,
                metrics: metrics, height: height, into: parent)
        case "end-repeat":
            drawRepeatDots(
                origin: origin, xOffset: -metrics.sp * 0.6,
                metrics: metrics, height: height, into: parent)
            line(dx: 0, width: metrics.sp * 0.15)
            line(dx: +metrics.sp * 0.3, width: metrics.sp * 0.4)
        default:
            line(dx: 0, width: metrics.sp * 0.15)
        }
    }

    private static func drawRepeatDots(
        origin: CGPoint, xOffset: CGFloat,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
    ) {
        let dotSize = metrics.sp * 0.3
        let half = dotSize / 2
        let top = CGRect(
            x: origin.x + xOffset - half,
            y: origin.y - metrics.sp / 2 - half,
            width: dotSize, height: dotSize)
        let bot = CGRect(
            x: origin.x + xOffset - half,
            y: origin.y + metrics.sp / 2 - half,
            width: dotSize, height: dotSize)
        parent.addSublayer(fillLayer(
            path: CGPath(ellipseIn: top, transform: nil),
            height: height))
        parent.addSublayer(fillLayer(
            path: CGPath(ellipseIn: bot, transform: nil),
            height: height))
    }

    // MARK: - Rest

    @discardableResult
    private static func drawRest(
        duration: NoteDuration, origin: CGPoint,
        hasLegerLine: Bool,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
    ) -> CAShapeLayer? {
        let (baseDur, dots) = DurationInterpretation.split(duration)
        let glyph: Character
        switch baseDur {
        case .whole:
            glyph = hasLegerLine
                ? SMuFLGlyph.restWholeLegerLine
                : SMuFLGlyph.restWhole
        case .half:
            glyph = hasLegerLine
                ? SMuFLGlyph.restHalfLegerLine
                : SMuFLGlyph.restHalf
        case .quarter: glyph = SMuFLGlyph.restQuarter
        case .eighth: glyph = SMuFLGlyph.rest8th
        case .sixteenth: glyph = SMuFLGlyph.rest16th
        case .thirtySecond: glyph = SMuFLGlyph.rest32nd
        case .sixtyFourth: glyph = SMuFLGlyph.rest64th
        default: glyph = SMuFLGlyph.restQuarter
        }
        let glyphLayerRef = glyphLayer(
            glyph, at: origin, size: metrics.glyphFontSize,
            height: height)
        if let layer = glyphLayerRef {
            parent.addSublayer(layer)
        }
        drawDots(
            after: origin, count: dots,
            onStaffLine: true,
            metrics: metrics, height: height, into: parent)
        return glyphLayerRef
    }

    // MARK: - Chord

    private static func drawChord(
        notes: [LayoutChordNote],
        duration: NoteDuration,
        stem: StemDirection,
        stemOrigin: CGPoint,
        isBeamed: Bool,
        base: CGPoint,
        metrics: StaffMetrics,
        height: CGFloat,
        context: inout BuildContext,
        into parent: CALayer
    ) {
        let (baseDur, dots) = DurationInterpretation.split(duration)
        let shifted = notes.map { n -> LayoutChordNote in
            LayoutChordNote(
                noteID: n.noteID,
                step: n.step,
                accidental: n.accidental,
                origin: CGPoint(
                    x: base.x + n.origin.x,
                    y: base.y + n.origin.y),
                tieForward: n.tieForward,
                tieBack: n.tieBack,
                hasGlissando: n.hasGlissando,
                headType: n.headType)
        }
        for n in shifted {
            let glyph = noteheadGlyph(
                for: baseDur, headType: n.headType)
            if let layer = glyphLayer(
                glyph, at: n.origin,
                size: metrics.glyphFontSize,
                height: height) {
                parent.addSublayer(layer)
                context.attach(layer, to: .note(n.noteID))
            }
            if let acc = n.accidental,
               let accLayer = drawAccidental(
                accidental: acc, origin: n.origin,
                metrics: metrics, height: height, into: parent) {
                context.attach(accLayer, to: .note(n.noteID))
            }
            drawDots(
                after: n.origin, count: dots,
                onStaffLine: n.step.isMultiple(of: 2),
                metrics: metrics, height: height, into: parent)
        }
        drawLedgerLines(
            notes: shifted, metrics: metrics,
            height: height, into: parent)
        let shiftedStemOrigin = CGPoint(
            x: base.x + stemOrigin.x,
            y: base.y + stemOrigin.y)
        let beamY: CGFloat? = isBeamed ? shiftedStemOrigin.y : nil
        // Extend the stem by one step (0.5 sp) when a dotted flagged
        // chord has the stem-side outer note sitting on a staff
        // line.  The dot is raised 0.5 sp to clear the line
        // (see `drawDots`), which otherwise lands inside the flag
        // glyph's visual bbox for a stem-up chord.  MuseScore's
        // engraver produces the same effect — the flag moves clear
        // of the raised dot.  For stem-down chords in our always-up
        // dot placement, the dot and flag are on opposite sides of
        // the notehead so no collision arises.
        let hasFlag = !isBeamed && isFlagged(baseDur)
        let stemUpTopOnLine = stem == .up
            && dots > 0
            && hasFlag
            && ((shifted.map(\.step).max() ?? 0).isMultiple(of: 2))
        let stemExtension: CGFloat = stemUpTopOnLine
            ? metrics.sp * 0.5
            : 0
        drawStem(
            notes: shifted, direction: stem, duration: baseDur,
            isBeamed: isBeamed, beamY: beamY,
            stemExtension: stemExtension,
            metrics: metrics, height: height, into: parent)
    }

    /// True when `dur` would normally be drawn with a flag (i.e.,
    /// 8th-note or shorter).  Used by the dot-on-line stem extension.
    private static func isFlagged(_ dur: NoteDuration) -> Bool {
        switch dur {
        case .eighth, .sixteenth, .thirtySecond, .sixtyFourth,
             .oneTwentyEighth, .twoFiftySixth:
            return true
        default:
            return false
        }
    }

    private static func noteheadGlyph(
        for duration: NoteDuration, headType: String?
    ) -> Character {
        switch headType {
        case "cross":
            switch duration {
            case .whole: return SMuFLGlyph.noteheadXWhole
            case .half:  return SMuFLGlyph.noteheadXHalf
            default:     return SMuFLGlyph.noteheadXBlack
            }
        case "diamond":
            switch duration {
            case .whole: return SMuFLGlyph.noteheadDiamondWhole
            case .half:  return SMuFLGlyph.noteheadDiamondHalf
            default:     return SMuFLGlyph.noteheadDiamondBlack
            }
        case "triangle-up":
            return SMuFLGlyph.noteheadTriangleUpBlack
        case "triangle-down":
            return SMuFLGlyph.noteheadTriangleDownBlack
        default:
            switch duration {
            case .whole: return SMuFLGlyph.noteheadWhole
            case .half:  return SMuFLGlyph.noteheadHalf
            default:     return SMuFLGlyph.noteheadBlack
            }
        }
    }

    // MARK: - Accidental

    @discardableResult
    private static func drawAccidental(
        accidental: Accidental, origin: CGPoint,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
    ) -> CAShapeLayer? {
        let glyph: Character
        switch accidental {
        case .sharp:       glyph = SMuFLGlyph.accidentalSharp
        case .flat:        glyph = SMuFLGlyph.accidentalFlat
        case .natural:     glyph = SMuFLGlyph.accidentalNatural
        case .doubleSharp: glyph = SMuFLGlyph.accidentalDoubleSharp
        case .doubleFlat:  glyph = SMuFLGlyph.accidentalDoubleFlat
        }
        guard let layer = glyphLayer(
            glyph,
            at: CGPoint(
                x: origin.x - metrics.sp * 1.2,
                y: origin.y),
            size: metrics.glyphFontSize,
            height: height)
        else { return nil }
        parent.addSublayer(layer)
        return layer
    }

    // MARK: - Dots

    private static func drawDots(
        after origin: CGPoint, count: Int,
        onStaffLine: Bool,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
    ) {
        guard count > 0 else { return }
        let radius = metrics.sp * 0.22
        let firstOffset = metrics.sp * 1.15
        let spacing = metrics.sp * 0.6
        let y = onStaffLine ? origin.y - metrics.sp / 2 : origin.y
        for i in 0..<count {
            let x = origin.x + firstOffset + CGFloat(i) * spacing
            let rect = CGRect(
                x: x - radius,
                y: y - radius,
                width: radius * 2,
                height: radius * 2)
            parent.addSublayer(fillLayer(
                path: CGPath(ellipseIn: rect, transform: nil),
                height: height))
        }
    }

    // MARK: - Ledger lines

    private static func drawLedgerLines(
        notes: [LayoutChordNote],
        metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer
    ) {
        guard let ref = notes.first else { return }
        let allSteps = notes.map(\.step)
        let maxStep = allSteps.max() ?? 0
        let minStep = allSteps.min() ?? 0
        guard maxStep > 4 || minStep < -4 else { return }

        let staffMidYAbs = ref.origin.y
            + CGFloat(ref.step) * metrics.sp / 2
        let chordX = ref.origin.x
        let halfWidth = metrics.sp * 0.9
        let lineWidth = metrics.staffLineThickness * 1.5

        if maxStep > 4 {
            let topEven = maxStep.isMultiple(of: 2)
                ? maxStep : maxStep - 1
            for ledgerStep in stride(
                from: 6, through: topEven, by: 2) {
                let y = staffMidYAbs
                    - CGFloat(ledgerStep) * metrics.sp / 2
                let path = CGMutablePath()
                path.move(to: CGPoint(
                    x: chordX - halfWidth, y: y))
                path.addLine(to: CGPoint(
                    x: chordX + halfWidth, y: y))
                parent.addSublayer(strokeLayer(
                    path: path, height: height,
                    lineWidth: lineWidth))
            }
        }

        if minStep < -4 {
            let botEven = minStep.isMultiple(of: 2)
                ? minStep : minStep + 1
            for ledgerStep in stride(
                from: -6, through: botEven, by: -2) {
                let y = staffMidYAbs
                    - CGFloat(ledgerStep) * metrics.sp / 2
                let path = CGMutablePath()
                path.move(to: CGPoint(
                    x: chordX - halfWidth, y: y))
                path.addLine(to: CGPoint(
                    x: chordX + halfWidth, y: y))
                parent.addSublayer(strokeLayer(
                    path: path, height: height,
                    lineWidth: lineWidth))
            }
        }
    }

    // MARK: - Stem + flag

    private static func drawStem(
        notes: [LayoutChordNote],
        direction: StemDirection,
        duration: NoteDuration,
        isBeamed: Bool,
        beamY: CGFloat?,
        stemExtension: CGFloat = 0,
        metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer
    ) {
        guard !notes.isEmpty else { return }
        if case .whole = duration { return }
        let xs = notes.map(\.origin.x)
        let ys = notes.map(\.origin.y)
        // Mirrors MuseScore's `TLayout::layoutStem`:
        //
        //   double lineWidthCorrection = item->lineWidthMag() * 0.5;
        //   double lineX = _up * lineWidthCorrection;
        //
        // The stem line is drawn at `stemPosX + lineX` where
        // stemPosX is the SMuFL anchor (stemUpSE.x for stem-up,
        // stemDownNW.x for stem-down) and lineX pulls the stem CENTER
        // inward by half the stem width, so the stem's FAR edge
        // (farther from the notehead body) lands exactly on
        // stemUpSE.x / stemDownNW.x.
        //
        // For Bravura's noteheadBlack at `.center`-anchored (glyph
        // width 1.18 sp, so bbox right = 0.59 sp from notehead
        // centre), the stem's far edge sits at ±0.59 sp from centre,
        // giving a stem centre offset of 0.59 sp - stemWidth/2.
        let stemAttachDx = metrics.sp * 0.59 - metrics.stemThickness / 2
        let xMin = xs.min() ?? 0
        let xMax = xs.max() ?? 0
        let yTop = ys.min() ?? 0
        let yBot = ys.max() ?? 0
        let xStem: CGFloat
        let startY: CGFloat
        let endY: CGFloat
        switch direction {
        case .up:
            xStem = xMax + stemAttachDx
            startY = beamY ?? (yTop - metrics.defaultStemLength - stemExtension)
            endY = yBot
        case .down:
            xStem = xMin - stemAttachDx
            startY = yTop
            endY = beamY ?? (yBot + metrics.defaultStemLength + stemExtension)
        }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: xStem, y: startY))
        path.addLine(to: CGPoint(x: xStem, y: endY))
        parent.addSublayer(strokeLayer(
            path: path, height: height,
            lineWidth: metrics.stemThickness))

        if isBeamed { return }
        if let flag = flagGlyph(
            for: duration, direction: direction) {
            let tipY: CGFloat = direction == .up ? startY : endY
            let font = bravuraFont(size: metrics.glyphFontSize)
            let ascent = CTFontGetAscent(font)
            if let layer = glyphLayer(
                flag,
                at: CGPoint(x: xStem, y: tipY - ascent),
                size: metrics.glyphFontSize,
                anchor: CGPoint(x: 0, y: 0),
                height: height) {
                parent.addSublayer(layer)
            }
        }
    }

    private static func flagGlyph(
        for dur: NoteDuration, direction: StemDirection
    ) -> Character? {
        switch (dur, direction) {
        case (.eighth, .up):        return SMuFLGlyph.flag8thUp
        case (.eighth, .down):      return SMuFLGlyph.flag8thDown
        case (.sixteenth, .up):     return SMuFLGlyph.flag16thUp
        case (.sixteenth, .down):   return SMuFLGlyph.flag16thDown
        case (.thirtySecond, .up):  return SMuFLGlyph.flag32ndUp
        case (.thirtySecond, .down):return SMuFLGlyph.flag32ndDown
        case (.sixtyFourth, .up):   return SMuFLGlyph.flag64thUp
        case (.sixtyFourth, .down): return SMuFLGlyph.flag64thDown
        default: return nil
        }
    }

    // MARK: - Beam

    private static func drawBeam(
        from: CGPoint, to: CGPoint,
        direction: StemDirection, level: Int,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
    ) {
        guard level >= 1 else { return }
        let beamThickness = metrics.sp * 0.5
        let beamGap = metrics.sp * 0.3
        let stackSign: CGFloat = direction == .up ? 1 : -1
        let dy = CGFloat(level - 1) * (beamThickness + beamGap) * stackSign
        let barInner = dy
        let barOuter = dy + beamThickness * stackSign
        let path = CGMutablePath()
        path.move(to: CGPoint(x: from.x, y: from.y + barInner))
        path.addLine(to: CGPoint(x: to.x, y: to.y + barInner))
        path.addLine(to: CGPoint(x: to.x, y: to.y + barOuter))
        path.addLine(to: CGPoint(x: from.x, y: from.y + barOuter))
        path.closeSubpath()
        parent.addSublayer(fillLayer(
            path: path, height: height))
    }

    // MARK: - Fermata

    private static func drawFermata(
        subtype: String, origin: CGPoint,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
    ) {
        let below = subtype.hasPrefix("fermataBelow")
        let glyph = below
            ? SMuFLGlyph.fermataBelow
            : SMuFLGlyph.fermataAbove
        if let layer = glyphLayer(
            glyph, at: origin,
            size: metrics.glyphFontSize,
            height: height) {
            parent.addSublayer(layer)
        }
    }

    // MARK: - Measure repeat

    private static func drawMeasureRepeat(
        count: Int, origin: CGPoint,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
    ) {
        let glyph: Character
        switch count {
        case 1: glyph = SMuFLGlyph.repeat1Bar
        case 2: glyph = SMuFLGlyph.repeat2Bars
        case 4: glyph = SMuFLGlyph.repeat4Bars
        default: glyph = SMuFLGlyph.repeat1Bar
        }
        if let layer = glyphLayer(
            glyph, at: origin,
            size: metrics.glyphFontSize,
            height: height) {
            parent.addSublayer(layer)
        }
    }

    // MARK: - Arpeggio

    private static func drawArpeggio(
        top: CGPoint, bottom: CGPoint, subtype: String?,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
    ) {
        let x = top.x - metrics.sp * 1.5
        var y = top.y
        while y <= bottom.y {
            if let layer = glyphLayer(
                SMuFLGlyph.arpeggioWiggle,
                at: CGPoint(x: x, y: y),
                size: metrics.glyphFontSize,
                height: height) {
                parent.addSublayer(layer)
            }
            y += metrics.sp
        }
        switch subtype {
        case "up":
            if let layer = glyphLayer(
                SMuFLGlyph.arpeggioUpArrow,
                at: CGPoint(x: x, y: top.y - metrics.sp),
                size: metrics.glyphFontSize,
                height: height) {
                parent.addSublayer(layer)
            }
        case "down":
            if let layer = glyphLayer(
                SMuFLGlyph.arpeggioDownArrow,
                at: CGPoint(x: x, y: bottom.y + metrics.sp),
                size: metrics.glyphFontSize,
                height: height) {
                parent.addSublayer(layer)
            }
        default:
            break
        }
    }

    // MARK: - Spanners

    private static func drawSpanner(
        kind: LayoutElement.SpannerKind,
        from: CGPoint, to: CGPoint,
        continuesLeft: Bool, continuesRight: Bool,
        text: String, metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer
    ) {
        switch kind {
        case .slur:
            drawSlur(
                from: from, to: to,
                metrics: metrics, height: height, into: parent)
        case .volta(let endings):
            drawVolta(
                from: from, to: to, endings: endings,
                continuesLeft: continuesLeft,
                continuesRight: continuesRight,
                metrics: metrics, height: height, into: parent)
        case .hairpinOpen, .hairpinClose:
            drawHairpin(
                from: from, to: to,
                open: kind == .hairpinOpen,
                metrics: metrics, height: height, into: parent)
        case .pedal:
            drawPedal(
                from: from, to: to,
                metrics: metrics, height: height, into: parent)
        case .ottava:
            drawOttava(
                from: from, to: to,
                metrics: metrics, height: height, into: parent)
        case .textLine:
            drawTextLine(
                from: from, to: to, text: text,
                metrics: metrics, height: height, into: parent)
        }
    }

    private static func drawSlur(
        from: CGPoint, to: CGPoint,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
    ) {
        let mid = CGPoint(
            x: (from.x + to.x) / 2,
            y: min(from.y, to.y) - metrics.sp * 2)
        let p = CGMutablePath()
        p.move(to: from)
        p.addQuadCurve(to: to, control: mid)
        parent.addSublayer(strokeLayer(
            path: p, height: height,
            lineWidth: metrics.sp * 0.15))
    }

    private static func drawVolta(
        from: CGPoint, to: CGPoint,
        endings: [Int],
        continuesLeft: Bool, continuesRight: Bool,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
    ) {
        let top = min(from.y, to.y)
        let p = CGMutablePath()
        if !continuesLeft {
            p.move(to: CGPoint(x: from.x, y: top + metrics.sp))
            p.addLine(to: CGPoint(x: from.x, y: top))
        } else {
            p.move(to: CGPoint(x: from.x, y: top))
        }
        p.addLine(to: CGPoint(x: to.x, y: top))
        if !continuesRight {
            p.addLine(to: CGPoint(x: to.x, y: top + metrics.sp))
        }
        parent.addSublayer(strokeLayer(
            path: p, height: height,
            lineWidth: metrics.sp * 0.15))
        if !endings.isEmpty, !continuesLeft {
            let label = endings
                .map(String.init)
                .joined(separator: ", ") + "."
            if let layer = textLayer(
                text: label,
                at: CGPoint(
                    x: from.x + metrics.sp,
                    y: top + metrics.sp / 2),
                size: metrics.sp * 2, italic: false,
                anchor: CGPoint(x: 0, y: 0.5),
                height: height) {
                parent.addSublayer(layer)
            }
        }
    }

    private static func drawHairpin(
        from: CGPoint, to: CGPoint, open: Bool,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
    ) {
        let p = CGMutablePath()
        let y = max(from.y, to.y)
        if open {
            p.move(to: CGPoint(x: from.x, y: y))
            p.addLine(to: CGPoint(x: to.x, y: y - metrics.sp))
            p.move(to: CGPoint(x: from.x, y: y))
            p.addLine(to: CGPoint(x: to.x, y: y + metrics.sp))
        } else {
            p.move(to: CGPoint(x: from.x, y: y - metrics.sp))
            p.addLine(to: CGPoint(x: to.x, y: y))
            p.move(to: CGPoint(x: from.x, y: y + metrics.sp))
            p.addLine(to: CGPoint(x: to.x, y: y))
        }
        parent.addSublayer(strokeLayer(
            path: p, height: height,
            lineWidth: metrics.sp * 0.15))
    }

    private static func drawPedal(
        from: CGPoint, to: CGPoint,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
    ) {
        if let layer = textLayer(
            text: "Ped.", at: from,
            size: metrics.sp * 2.5, italic: true,
            anchor: CGPoint(x: 0, y: 0.5),
            height: height) {
            parent.addSublayer(layer)
        }
        if let layer = textLayer(
            text: "*", at: to,
            size: metrics.sp * 3, italic: false,
            anchor: CGPoint(x: 0, y: 0.5),
            height: height) {
            parent.addSublayer(layer)
        }
    }

    private static func drawOttava(
        from: CGPoint, to: CGPoint,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
    ) {
        if let layer = textLayer(
            text: "8va", at: from,
            size: metrics.sp * 2.5, italic: true,
            anchor: CGPoint(x: 0, y: 0.5),
            height: height) {
            parent.addSublayer(layer)
        }
        let p = CGMutablePath()
        p.move(to: CGPoint(x: from.x + metrics.sp * 3, y: from.y))
        p.addLine(to: to)
        parent.addSublayer(strokeLayer(
            path: p, height: height,
            lineWidth: metrics.sp * 0.1,
            dashPattern: [3, 3]))
    }

    private static func drawTextLine(
        from: CGPoint, to: CGPoint, text: String,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
    ) {
        if !text.isEmpty,
           let layer = textLayer(
            text: text, at: from,
            size: metrics.sp * 2.2, italic: true,
            anchor: CGPoint(x: 0, y: 0.5),
            height: height) {
            parent.addSublayer(layer)
        }
        let p = CGMutablePath()
        p.move(to: from)
        p.addLine(to: to)
        parent.addSublayer(strokeLayer(
            path: p, height: height,
            lineWidth: metrics.sp * 0.1))
    }

    // MARK: - Tie arc

    private static func drawTieArc(
        from: CGPoint, to: CGPoint, above: Bool,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
    ) {
        let headClearance = metrics.sp * 0.6
        let vertSign: CGFloat = above ? -1 : 1
        let startPt = CGPoint(
            x: from.x,
            y: from.y + headClearance * vertSign)
        let endPt = CGPoint(
            x: to.x,
            y: to.y + headClearance * vertSign)

        let minShoulder = metrics.sp * 0.3
        let maxShoulder = metrics.sp * 2.0
        let tieLen = abs(endPt.x - startPt.x)
        let tieLenSp = max(tieLen / metrics.sp, 1.0)
        let shoulderH: CGFloat = {
            let raw = minShoulder
                + metrics.sp * 0.3 * sqrt(tieLenSp - 1)
            return min(max(raw, minShoulder), maxShoulder)
        }()
        let midThickness = metrics.sp * 0.15

        let dx = endPt.x - startPt.x
        let dy = endPt.y - startPt.y
        let ctrl1 = CGPoint(
            x: startPt.x + dx * 0.2,
            y: startPt.y + dy * 0.2 + shoulderH * vertSign)
        let ctrl2 = CGPoint(
            x: startPt.x + dx * 0.8,
            y: startPt.y + dy * 0.8 + shoulderH * vertSign)
        let thickDy = midThickness * vertSign * -1

        let path = CGMutablePath()
        path.move(to: startPt)
        path.addCurve(
            to: endPt,
            control1: CGPoint(x: ctrl1.x, y: ctrl1.y - thickDy),
            control2: CGPoint(x: ctrl2.x, y: ctrl2.y - thickDy))
        path.addCurve(
            to: startPt,
            control1: CGPoint(x: ctrl2.x, y: ctrl2.y + thickDy),
            control2: CGPoint(x: ctrl1.x, y: ctrl1.y + thickDy))
        path.closeSubpath()
        parent.addSublayer(fillLayer(
            path: path, height: height))
    }

    // MARK: - Glissando

    private static func drawGlissando(
        from: CGPoint, to: CGPoint, wavy: Bool, text: String?,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
    ) {
        let dx = to.x - from.x
        let dy = to.y - from.y
        let length = sqrt(dx * dx + dy * dy)
        guard length > 0.01 else { return }
        let angle = atan2(dy, dx)

        let linePath = CGMutablePath()
        if wavy {
            let waveAmp = metrics.sp * 0.3
            let segments = max(3, Int(length / (metrics.sp * 0.8)))
            let segLen = length / CGFloat(segments)
            linePath.move(to: .zero)
            for i in 1...segments {
                let x = segLen * CGFloat(i)
                let y = i.isMultiple(of: 2) ? waveAmp : -waveAmp
                linePath.addLine(to: CGPoint(x: x, y: y))
            }
        } else {
            linePath.move(to: .zero)
            linePath.addLine(to: CGPoint(x: length, y: 0))
        }
        // Want: P → rotate(P) → + from.
        // Matrix: T_from · R.  In CGAffineTransform chained API, each
        // method post-multiplies its operation onto the receiver, so
        // the chain must be translate-then-rotate:
        //   I.translatedBy(from) · R = T_from · R
        var transform = CGAffineTransform(
            translationX: from.x, y: from.y)
        transform = transform.rotated(by: angle)
        if let transformed = linePath.copy(using: &transform) {
            parent.addSublayer(strokeLayer(
                path: transformed, height: height,
                lineWidth: metrics.sp * 0.15))
        }

        if let text, !text.isEmpty {
            let localX = length / 2
            let localY = -(metrics.sp * 0.5)
            let worldX = cos(angle) * localX
                - sin(angle) * localY + from.x
            let worldY = sin(angle) * localX
                + cos(angle) * localY + from.y
            if let layer = textLayer(
                text: text,
                at: CGPoint(x: worldX, y: worldY),
                size: metrics.sp * 1.8,
                italic: true,
                anchor: CGPoint(x: 0.5, y: 0.5),
                rotation: angle,
                height: height) {
                parent.addSublayer(layer)
            }
        }
    }

    // MARK: - Tuplet

    private static func drawTuplet(
        from: CGPoint, to: CGPoint, text: String,
        hasBracket: Bool, isAbove: Bool,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
    ) {
        let fontSize = metrics.sp * 2
        let labelX = (from.x + to.x) / 2
        let labelY = (from.y + to.y) / 2
        if let layer = textLayer(
            text: text,
            at: CGPoint(x: labelX, y: labelY),
            size: fontSize, italic: true,
            anchor: CGPoint(x: 0.5, y: 0.5),
            height: height) {
            parent.addSublayer(layer)
        }
        guard hasBracket else { return }
        let labelHalfWidth = fontSize * 0.4
        let hook = metrics.sp * 0.8
        let hookSign: CGFloat = isAbove ? 1 : -1
        let hookDy = hook * hookSign
        let lineWidth = metrics.sp * 0.12

        for endpoint in [from, to] {
            let p = CGMutablePath()
            p.move(to: CGPoint(
                x: endpoint.x,
                y: endpoint.y + hookDy))
            p.addLine(to: endpoint)
            parent.addSublayer(strokeLayer(
                path: p, height: height, lineWidth: lineWidth))
        }
        let leftSeg = CGMutablePath()
        leftSeg.move(to: from)
        leftSeg.addLine(to: CGPoint(
            x: labelX - labelHalfWidth,
            y: interpY(
                from: from, to: to,
                x: labelX - labelHalfWidth)))
        parent.addSublayer(strokeLayer(
            path: leftSeg, height: height, lineWidth: lineWidth))
        let rightSeg = CGMutablePath()
        rightSeg.move(to: CGPoint(
            x: labelX + labelHalfWidth,
            y: interpY(
                from: from, to: to,
                x: labelX + labelHalfWidth)))
        rightSeg.addLine(to: to)
        parent.addSublayer(strokeLayer(
            path: rightSeg, height: height, lineWidth: lineWidth))
    }

    private static func interpY(
        from: CGPoint, to: CGPoint, x: CGFloat
    ) -> CGFloat {
        let span = to.x - from.x
        guard abs(span) > 0.01 else { return from.y }
        let t = (x - from.x) / span
        return from.y + (to.y - from.y) * t
    }

    // MARK: - Marker

    private static func drawMarker(
        kind: Marker.Kind, text: String, origin: CGPoint,
        metrics: StaffMetrics, height: CGFloat,
        into parent: CALayer
    ) {
        switch kind {
        case .segno, .varsegno:
            if let layer = glyphLayer(
                SMuFLGlyph.segno, at: origin,
                size: metrics.glyphFontSize,
                height: height) {
                parent.addSublayer(layer)
            }
        case .coda, .varcoda, .codetta, .toCodaSym:
            if let layer = glyphLayer(
                SMuFLGlyph.coda, at: origin,
                size: metrics.glyphFontSize,
                height: height) {
                parent.addSublayer(layer)
            }
        case .fine, .toCoda, .daCapo, .dalSegno, .other:
            let label = text.isEmpty
                ? fallbackMarkerLabel(for: kind) : text
            if let layer = textLayer(
                text: label, at: origin,
                size: metrics.sp * 2.5, italic: false,
                anchor: CGPoint(x: 0, y: 0.5),
                height: height) {
                parent.addSublayer(layer)
            }
        }
    }

    private static func fallbackMarkerLabel(
        for kind: Marker.Kind
    ) -> String {
        switch kind {
        case .fine: return "Fine"
        case .toCoda: return "To Coda"
        case .daCapo: return "D.C."
        case .dalSegno: return "D.S."
        case .other: return ""
        default: return ""
        }
    }
}
