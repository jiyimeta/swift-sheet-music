import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, iOS 16.0, *)
enum ArticulationRenderer {
    /// Draw one articulation glyph at `origin` using the SMuFL
    /// codepoint that matches `(kind, isAbove)`. The glyph anchor
    /// matches Bravura's metrics: U+E4A2/E4A4/E4A6 sit just below
    /// their baseline (above variants) and U+E4A3/E4A5/E4A7 sit just
    /// above (below variants), so the same `origin` works for both.
    static func draw(
        context: inout GraphicsContext,
        kind: LayoutElement.ArticulationKind,
        isAbove: Bool,
        origin: CGPoint,
        metrics: StaffMetrics
    ) {
        let glyph: Character
        switch (kind, isAbove) {
        case (.staccato, true): glyph = SMuFLGlyph.articStaccatoAbove
        case (.staccato, false): glyph = SMuFLGlyph.articStaccatoBelow
        case (.staccatissimo, true): glyph = SMuFLGlyph.articStaccatissimoAbove
        case (.staccatissimo, false): glyph = SMuFLGlyph.articStaccatissimoBelow
        case (.tenuto, true): glyph = SMuFLGlyph.articTenutoAbove
        case (.tenuto, false): glyph = SMuFLGlyph.articTenutoBelow
        }
        context.drawGlyph(
            glyph, at: origin, size: metrics.glyphFontSize
        )
    }
}
