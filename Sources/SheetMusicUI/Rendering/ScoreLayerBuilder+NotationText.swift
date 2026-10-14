import QuartzCore
import SheetMusicCore
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
}
