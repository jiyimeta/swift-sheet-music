import QuartzCore
import SheetMusicLayout
import SheetMusicLayoutApple

@available(macOS 15.0, *)
extension ScoreLayerBuilder {
    /// Y-down outlines of positioned runs — each in the font the layout measured it in, at the pen position the layout
    /// computed — plus their underline and strike-through bars as filled rects. Shared by the CALayer tree, the Canvas
    /// and the title block, so the three cannot drift from each other or from layout.
    static func richTextPath(
        runs: [LayoutRichTextPositionedRun], decorations: [LayoutRichTextDecoration],
    ) -> CGPath? {
        let provider = AppleFontMetricsProvider()
        let composite = CGMutablePath()
        for run in runs {
            guard let outline = textPath(run.content.string, font: provider.renderingFont(for: run.font)) else {
                continue
            }
            composite.addPath(
                outline, transform: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: run.baseline.x, ty: run.baseline.y),
            )
        }
        guard !decorations.isEmpty else { return composite.isEmpty ? nil : composite }
        // The bars are united with the glyphs rather than added to their path: both fills (CAShapeLayer,
        // GraphicsContext) are non-zero winding, and the flipped outline of a PostScript (CFF) font winds opposite to
        // `addRect`, so where a bar crossed a stroke the winding summed to 0 and left a hole. `union` resolves each
        // operand on its own first, so the result fills the same whatever the contour direction. Only decorated text
        // pays for it.
        let bars = CGMutablePath()
        for bar in decorations {
            bars.addRect(bar.rect)
        }
        return composite.isEmpty ? bars : composite.union(bars)
    }

    /// A text element's runs placed at `origin` by `anchor` (`LayoutRichText.positionedRuns(at:anchor:)`). The anchor
    /// is the one layout measured the element's ink with (`TextInkGeometry`).
    static func richTextPath(_ richText: LayoutRichText, origin: CGPoint, anchor: CGPoint) -> CGPath? {
        richTextPath(
            runs: richText.positionedRuns(at: origin, anchor: anchor),
            decorations: richText.decorations(at: origin, anchor: anchor),
        )
    }

    static func richTextLayer(
        _ richText: LayoutRichText, at origin: CGPoint, anchor: CGPoint, color: CGColor, height: CGFloat,
    ) -> CAShapeLayer? {
        richTextPath(richText, origin: origin, anchor: anchor).map { fillLayer(path: $0, height: height, color: color) }
    }
}
