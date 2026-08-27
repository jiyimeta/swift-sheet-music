import SheetMusicLayout
import SwiftUI

/// Draws a guitar bend on a standard (non-tablature) staff.
///
/// Two shapes, matching the two paths `GuitarBendLayout` builds
/// (`rendering/score/guitarbendlayout.cpp`):
///
/// * **Angular bend** — the two-segment polyline `from → vertex → to`
///   that `layoutAngularBend` stores (`:212-215`, two `lineTo`s from
///   the implicit origin).
/// * **Slight bend** — the fixed cubic hook of `layoutSlightBend`
///   (`:379-381`): `path.cubicTo(PointF(0, 0), curve, pos2())`. The
///   FIRST control point is the start anchor itself, so the hook leaves
///   the notehead along the chord of the curve; the second is the
///   vertex.
///
/// Both are stroked with no brush — upstream sets
/// `BrushStyle::NoBrush` before `drawPath` — at `item->lineWidth()`
/// with flat caps and miter joins
/// (`TDraw::draw(const GuitarBendSegment*)`, `tdraw.cpp:1636-1655`).
/// The bevel-join branch there is the `DIP` whammy type, which this
/// package does not model.
@available(macOS 15.0, *)
enum GuitarBendRenderer {
    static func draw(
        context: inout GraphicsContext,
        from: CGPoint,
        vertex: CGPoint,
        to: CGPoint,
        slight: Bool,
        metrics: StaffMetrics,
    ) {
        context.stroke(
            path(from: from, vertex: vertex, to: to, slight: slight),
            with: .color(.primary),
            style: StrokeStyle(
                lineWidth: metrics.sp * GuitarBendGeometry.lineThicknessSp,
                lineCap: .butt,
                lineJoin: .miter,
            ),
        )
    }

    /// The bend outline. All three points arrive in the same frame the
    /// path is drawn in, so no local/world conversion is needed (unlike
    /// `GlissandoRenderer`, which rotates into the line's own frame to
    /// place its label).
    private static func path(
        from: CGPoint, vertex: CGPoint, to: CGPoint, slight: Bool,
    ) -> Path {
        var path = Path()
        path.move(to: from)
        if slight {
            path.addCurve(to: to, control1: from, control2: vertex)
        } else {
            path.addLine(to: vertex)
            path.addLine(to: to)
        }
        return path
    }
}
