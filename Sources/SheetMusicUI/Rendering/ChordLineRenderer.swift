import SheetMusicLayout
import SwiftUI

/// Draws a jazz/brass inflection line — fall, doit, plop, or scoop.
///
/// The default and "slide" palette variants are a stroked bezier /
/// straight segment; the "rough" variants are a single SMuFL wiggle
/// glyph rotated by ±1°. Mirrors `TDraw::draw(const ChordLine*, …)`
/// (`rendering/score/tdraw.cpp`).
@available(macOS 15.0, *)
enum ChordLineRenderer {
    static func draw(
        context: inout GraphicsContext,
        shape: ChordLineShape,
        origin: CGPoint,
        thickness: CGFloat,
        color: Color = .primary,
        metrics: StaffMetrics,
    ) {
        switch shape {
        case let .path(segments):
            guard !segments.isEmpty else { return }
            var path = Path()
            path.move(to: origin)
            for segment in segments {
                switch segment {
                case let .move(to):
                    path.move(to: offset(to, by: origin))
                case let .line(to):
                    path.addLine(to: offset(to, by: origin))
                case let .curve(control1, control2, to):
                    path.addCurve(
                        to: offset(to, by: origin),
                        control1: offset(control1, by: origin),
                        control2: offset(control2, by: origin),
                    )
                }
            }
            // No fill — upstream sets `BrushStyle::NoBrush`, so an open
            // curve must not be closed off into a filled wedge.
            context.stroke(
                path, with: .color(color), lineWidth: thickness,
            )

        case let .glyph(codepoint, rotationDegrees):
            guard let scalar = UnicodeScalar(codepoint) else { return }
            var local = context
            local.translateBy(x: origin.x, y: origin.y)
            local.rotate(by: .degrees(rotationDegrees))
            local.drawGlyph(
                Character(scalar),
                at: .zero,
                size: metrics.glyphFontSize,
                color: color,
            )
        }
    }

    private static func offset(_ point: CGPoint, by origin: CGPoint) -> CGPoint {
        CGPoint(x: origin.x + point.x, y: origin.y + point.y)
    }
}
