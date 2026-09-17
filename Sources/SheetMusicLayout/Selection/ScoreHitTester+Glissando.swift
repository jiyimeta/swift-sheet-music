#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
import SheetMusicFoundation

/// Hit geometry for a glissando line: the straight stroke or wiggle-glyph run between two noteheads, plus the label
/// the renderers draw above its middle — all of it rotated to the line's slope.
///
/// Everything is measured in the line's own frame (origin at `fromOrigin`, x along the line, y across it), the frame
/// `GlissandoGeometry` builds the drawing in, so the ink a click is tested against is the ink that was drawn. A
/// slanted line's bounding box never stands in for the line: that box also covers the two empty triangles beside it.
@available(macOS 15.0, *)
extension ScoreHitTester {
    /// Returns nil only for a non-glissando. A rejected glissando never falls through to rectangle acceptance, just
    /// as a rejected arc does not.
    ///
    /// The line takes a click within `curveHitToleranceSp` of its band — the centerline for a straight stroke, as a
    /// tie or slur is measured from its centerline, and the glyph run's ink for a wavy line, whose wiggle is several
    /// times a stroke wide. The label takes one within `textHitTolerance` of its ink, as engraved text does.
    func glissandoContains(_ element: LayoutElement, point: CGPoint) -> Bool? {
        guard let shape = glissandoShape(element) else { return nil }
        let sp = document.metrics.sp
        let local = shape.local(point)
        if shape.band.distance(to: local) <= sp * Self.curveHitToleranceSp { return true }
        guard let label = shape.label else { return false }
        let reach = sp * Self.textHitTolerance
        return label.insetBy(dx: -reach, dy: -reach).contains(local)
    }

    /// The drawn line — a straight stroke's width included — and, when one is drawn, its label: each the
    /// axis-aligned box around its rotated ink, without hit tolerance. nil for a non-glissando.
    func glissandoInkRects(_ element: LayoutElement) -> [CGRect]? {
        guard let shape = glissandoShape(element) else { return nil }
        let halfStroke = shape.wavy ? 0 : document.metrics.sp * GlissandoGeometry.lineThicknessSp / 2
        let line = shape.band.insetBy(dx: 0, dy: -halfStroke)
        return ([line] + (shape.label.map { [$0] } ?? [])).map(shape.worldBounds)
    }

    private func glissandoShape(_ element: LayoutElement) -> GlissandoHitShape? {
        guard case let .glissandoLine(from, to, wavy, text, _) = element else { return nil }
        let length = GlissandoGeometry.length(from: from, to: to)
        let ink = wavy ? wiggleInkBand() : (minY: CGFloat(0), height: CGFloat(0))
        return GlissandoHitShape(
            from: from,
            angle: GlissandoGeometry.angle(from: from, to: to),
            wavy: wavy,
            band: CGRect(x: 0, y: ink.minY, width: length, height: ink.height),
            label: text.flatMap { glissandoLabel($0, length: length, wavy: wavy) },
        )
    }

    /// The wiggle glyph's ink across the line, anchored as the renderers anchor it — centered on the line by its text
    /// band, the same placement `glyphInkRects` measures a glyph with. A zero-height band (the centerline) when the
    /// font reports no bounds for it.
    private func wiggleInkBand() -> (minY: CGFloat, height: CGFloat) {
        let font = LayoutFont(face: SMuFLFamily.bravura, pointSize: document.metrics.glyphFontSize)
        let provider = FontMetrics.provider
        guard let box = provider.glyphPathBoundingBox(
            font: font, codepoint: UInt16(truncatingIfNeeded: SMuFLCodepoint.wiggleGlissando),
        ), box.height > 0 else { return (0, 0) }
        let baselineOffset = (provider.ascent(font: font) - provider.descent(font: font)) / 2
        return (baselineOffset - box.maxY, box.height)
    }

    /// The label's ink in the line's frame, or nil where the renderers draw none: they print it only when its
    /// typographic width is shorter than the line (`tdraw.cpp:1580`), so a label too wide for a short line claims
    /// nothing — nor does the END half of a split line, which carries no text at all.
    private func glissandoLabel(_ text: String, length: CGFloat, wavy: Bool) -> CGRect? {
        guard !text.isEmpty else { return nil }
        let metrics = document.metrics
        let font = TextInkGeometry.font(for: .glissando, metrics: metrics)
        guard TextInkGeometry.typographicSize(text: text, font: font).width < length else { return nil }
        return TextInkGeometry.rect(
            text: text, font: font,
            origin: GlissandoGeometry.textAnchorLocal(length: length, wavy: wavy, sp: metrics.sp),
            anchor: CGPoint(x: 0.5, y: 1),
        )
    }
}

/// One glissando segment in its own rotated frame; see `ScoreHitTester.glissandoContains`.
private struct GlissandoHitShape {
    let from: CGPoint
    let angle: CGFloat
    let wavy: Bool
    /// The line's ink over x ∈ [0, length]. Zero height for a straight stroke, whose centerline it is.
    let band: CGRect
    let label: CGRect?

    /// `point` in the line's frame — the inverse of `GlissandoGeometry.toWorld`.
    func local(_ point: CGPoint) -> CGPoint {
        let dx = point.x - from.x
        let dy = point.y - from.y
        let cosA = cos(angle)
        let sinA = sin(angle)
        return CGPoint(x: cosA * dx + sinA * dy, y: -sinA * dx + cosA * dy)
    }

    /// The axis-aligned box around `rect`'s four corners, rotated back into the element's own frame.
    func worldBounds(_ rect: CGRect) -> CGRect {
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
        ].map { GlissandoGeometry.toWorld(local: $0, from: from, angle: angle) }
        let minX = corners.map(\.x).min() ?? from.x
        let maxX = corners.map(\.x).max() ?? from.x
        let minY = corners.map(\.y).min() ?? from.y
        let maxY = corners.map(\.y).max() ?? from.y
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

extension CGRect {
    /// Euclidean distance from `point` to this rectangle's nearest point; zero on or inside it.
    fileprivate func distance(to point: CGPoint) -> CGFloat {
        let dx = Swift.max(minX - point.x, 0, point.x - maxX)
        let dy = Swift.max(minY - point.y, 0, point.y - maxY)
        return (dx * dx + dy * dy).squareRoot()
    }
}
