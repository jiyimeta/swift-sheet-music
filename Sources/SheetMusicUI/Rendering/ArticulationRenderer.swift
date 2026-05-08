import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, iOS 16.0, *)
enum ArticulationRenderer {
    /// SMuFL codepoint for the given articulation kind on the given
    /// side. Above/below pairs render the same shape mirrored across
    /// the baseline; the glyph anchor matches Bravura's metrics so the
    /// same `origin` works for both. Shared by the `GraphicsContext`
    /// path here and the `CALayer` path in `ScoreLayerBuilder+Misc`.
    static func glyph(
        kind: LayoutElement.ArticulationKind,
        isAbove: Bool
    ) -> Character {
        switch (kind, isAbove) {
        case (.staccato, true): return SMuFLGlyph.articStaccatoAbove
        case (.staccato, false): return SMuFLGlyph.articStaccatoBelow
        case (.staccatissimo, true): return SMuFLGlyph.articStaccatissimoAbove
        case (.staccatissimo, false): return SMuFLGlyph.articStaccatissimoBelow
        case (.tenuto, true): return SMuFLGlyph.articTenutoAbove
        case (.tenuto, false): return SMuFLGlyph.articTenutoBelow
        case (.accent, true): return SMuFLGlyph.articAccentAbove
        case (.accent, false): return SMuFLGlyph.articAccentBelow
        case (.marcato, true): return SMuFLGlyph.articMarcatoAbove
        case (.marcato, false): return SMuFLGlyph.articMarcatoBelow
        case (.accentStaccato, true): return SMuFLGlyph.articAccentStaccatoAbove
        case (.accentStaccato, false): return SMuFLGlyph.articAccentStaccatoBelow
        case (.marcatoStaccato, true): return SMuFLGlyph.articMarcatoStaccatoAbove
        case (.marcatoStaccato, false): return SMuFLGlyph.articMarcatoStaccatoBelow
        }
    }

    /// Draw one articulation glyph at `origin`.
    static func draw(
        context: inout GraphicsContext,
        kind: LayoutElement.ArticulationKind,
        isAbove: Bool,
        origin: CGPoint,
        metrics: StaffMetrics
    ) {
        context.drawGlyph(
            glyph(kind: kind, isAbove: isAbove),
            at: origin,
            size: metrics.glyphFontSize
        )
    }
}
