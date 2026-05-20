import SheetMusicLayout
import SwiftUI

@available(macOS 15.0, *)
enum ArticulationRenderer {
    /// `Character`-typed wrapper around `ArticulationGlyph.codepoint`.
    /// SwiftUI's `GraphicsContext.drawGlyph` takes a `Character`, and
    /// the `CALayer` path uses the same conversion.
    static func glyph(
        kind: LayoutElement.ArticulationKind,
        isAbove: Bool,
    ) -> Character {
        let cp = ArticulationGlyph.codepoint(kind: kind, isAbove: isAbove)
        // swiftlint:disable:next force_unwrapping
        return Character(UnicodeScalar(cp)!)
    }

    /// Draw one articulation glyph at `origin`.
    static func draw(
        context: inout GraphicsContext,
        kind: LayoutElement.ArticulationKind,
        isAbove: Bool,
        origin: CGPoint,
        metrics: StaffMetrics,
    ) {
        context.drawGlyph(
            glyph(kind: kind, isAbove: isAbove),
            at: origin,
            size: metrics.glyphFontSize,
        )
    }
}
