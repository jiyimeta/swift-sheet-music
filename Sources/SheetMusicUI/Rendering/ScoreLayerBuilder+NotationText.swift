import QuartzCore
import SheetMusicLayout
import SheetMusicLayoutApple

@available(macOS 15.0, *)
extension ScoreLayerBuilder {
    static func notationTextLayer(
        text: String, role: NotationTextStyle.Role, origin: CGPoint,
        metrics: StaffMetrics, height: CGFloat,
    ) -> CAShapeLayer? {
        let font = NotationTextStyle.font(for: role, sp: metrics.sp)
        return textLayer(
            text: text, at: origin, size: font.pointSize, italic: font.isItalic,
            anchor: NotationTextStyle.anchorPoint(for: role),
            font: AppleFontMetricsProvider().renderingFont(for: font), height: height,
        )
    }

    static func drawTempoText(
        text: String, origin: CGPoint, metrics: StaffMetrics, height: CGFloat, into parent: CALayer,
    ) {
        let provider = AppleFontMetricsProvider()
        for run in TextInkGeometry.tempoRuns(text: text, origin: origin, metrics: metrics) {
            guard let path = textPath(run.text, font: provider.renderingFont(for: run.font)) else { continue }
            var transform = CGAffineTransform(
                a: 1,
                b: 0,
                c: 0,
                d: -1,
                tx: run.baseline.x,
                ty: run.baseline.y,
            )
            guard let shifted = path.copy(using: &transform) else { continue }
            parent.addSublayer(fillLayer(path: shifted, height: height))
        }
    }
}
