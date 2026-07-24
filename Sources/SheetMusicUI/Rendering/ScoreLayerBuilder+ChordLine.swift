import QuartzCore
import SheetMusicCore
import SheetMusicLayout

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

@available(macOS 15.0, *)
extension ScoreLayerBuilder {
    // MARK: - Chord line (fall / doit / plop / scoop)

    /// CALayer counterpart of `ChordLineRenderer`. Mirrors
    /// `TDraw::draw(const ChordLine*, …)`: stroke the path with
    /// `Sid::chordlineThickness` and no brush, or draw the wave glyph
    /// rotated by ±1°.
    static func drawChordLine(
        shape: ChordLineShape,
        origin: CGPoint,
        thickness: CGFloat,
        metrics: StaffMetrics,
        height: CGFloat,
        into parent: CALayer,
    ) {
        switch shape {
        case let .path(segments):
            guard !segments.isEmpty else { return }
            let path = CGMutablePath()
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
            parent.addSublayer(strokeLayer(
                path: path, height: height, lineWidth: thickness,
            ))

        case let .glyph(codepoint, rotationDegrees):
            guard let scalar = UnicodeScalar(codepoint) else { return }
            if let layer = glyphLayer(
                Character(scalar),
                at: origin,
                size: metrics.glyphFontSize,
                rotation: rotationDegrees * .pi / 180,
                height: height,
            ) {
                parent.addSublayer(layer)
            }
        }
    }

    private static func offset(
        _ point: CGPoint, by origin: CGPoint,
    ) -> CGPoint {
        CGPoint(x: origin.x + point.x, y: origin.y + point.y)
    }
}
