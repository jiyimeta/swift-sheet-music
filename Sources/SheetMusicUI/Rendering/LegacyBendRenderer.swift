import SheetMusicLayout
import SwiftUI

/// Draws a legacy (pre-4.2) MuseScore bend — `TDraw::draw(const Bend*)`,
/// `rendering/score/tdraw.cpp:939`.
///
/// The shape arrives fully resolved from `LegacyBendGeometry` (see that
/// file for the C++ provenance of the pieces themselves), so this only
/// has to ink it:
///
/// * **Lines and curves** are stroked as one path with the bend pen
///   (`tdraw.cpp:951`): `Sid::bendLineWidth` wide, `RoundCap` and
///   `RoundJoin`. That pen is deliberately different from
///   `GuitarBendRenderer`'s flat/miter one — the 4.2 rewrite changed it.
/// * **Arrowheads** are FILLED triangles `aw` wide and `aw` tall
///   (`tdraw.cpp:963-966`, `PolygonF` + `drawPolygon` with the pen's
///   colour as the brush), pointing up or down off the leg they close.
/// * **Labels** ("full", "1/2", …) sit above the arrow tip, centered
///   horizontally with their bottom on the tip (`AlignHCenter |
///   AlignBottom`, `tdraw.cpp:967`).
@available(macOS 15.0, *)
enum LegacyBendRenderer {
    static func draw(
        context: inout GraphicsContext,
        shape: LegacyBendShape,
        metrics: StaffMetrics,
    ) {
        let outline = outlinePath(for: shape)
        if !outline.isEmpty {
            context.stroke(
                Path(outline),
                with: .color(.primary),
                style: StrokeStyle(
                    lineWidth: metrics.sp
                        * LegacyBendGeometry.lineThicknessSp,
                    lineCap: .round,
                    lineJoin: .round,
                ),
            )
        }

        let arrowWidth = metrics.sp * LegacyBendGeometry.arrowWidthSp
        for piece in shape.pieces {
            switch piece {
            case let .arrow(tip, up):
                context.fill(
                    Path(arrowPath(
                        tip: tip, up: up, arrowWidth: arrowWidth,
                    )),
                    with: .color(.primary),
                )
            case let .label(text, anchor):
                drawLabel(
                    text, anchor: anchor,
                    context: &context, metrics: metrics,
                )
            case .line, .curve:
                continue
            }
        }
    }

    /// The stroked outline — every `.line` and `.curve` piece in one
    /// path, each starting with its own `move` because the pieces are
    /// stored with absolute endpoints and need not be contiguous.
    ///
    /// Shared with the CALayer builder so both paths are provably the
    /// same geometry; only the pen is restated at each call site.
    static func outlinePath(for shape: LegacyBendShape) -> CGPath {
        let path = CGMutablePath()
        for piece in shape.pieces {
            switch piece {
            case let .line(from, to):
                path.move(to: from)
                path.addLine(to: to)
            case let .curve(from, control1, control2, to):
                path.move(to: from)
                path.addCurve(
                    to: to, control1: control1, control2: control2,
                )
            case .arrow, .label:
                continue
            }
        }
        return path
    }

    /// One arrowhead: an isosceles triangle whose apex is the leg's end
    /// point and whose base sits `arrowWidth` behind it — up-arrows put
    /// the base BELOW the tip (positive y in the layout's Y-down frame),
    /// down-arrows above (`tdraw.cpp:963-966`).
    static func arrowPath(
        tip: CGPoint, up: Bool, arrowWidth: CGFloat,
    ) -> CGPath {
        let depth = up ? arrowWidth : -arrowWidth
        let path = CGMutablePath()
        path.move(to: tip)
        path.addLine(to: CGPoint(
            x: tip.x + arrowWidth / 2, y: tip.y + depth,
        ))
        path.addLine(to: CGPoint(
            x: tip.x - arrowWidth / 2, y: tip.y + depth,
        ))
        path.closeSubpath()
        return path
    }

    /// Bend amount above the arrow tip. Font defaults via
    /// `TextStyleType.bend` (Edwin 8 pt normal, spatium-dependent);
    /// unlike the glissando label there is no width gate — MuseScore
    /// always draws it.
    private static func drawLabel(
        _ text: String,
        anchor: CGPoint,
        context: inout GraphicsContext,
        metrics: StaffMetrics,
    ) {
        guard !text.isEmpty else { return }
        let style = ResolvedTextStyle.resolve(.bend, metrics: metrics)
        let label = Text(text)
            .foregroundColor(.primary)
            .font(style.font)
        context.draw(
            context.resolve(label),
            at: anchor,
            anchor: UnitPoint(x: 0.5, y: 1.0),
        )
    }
}
