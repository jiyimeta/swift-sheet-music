import CoreGraphics
import SheetMusicLayout

/// A `LayoutFigure` as the paths the Apple renderers draw: one fill (filled ellipses and every run's outline) and a
/// stroke per line, polyline, stroked ellipse and outline rect — in the figure's own y-down coordinates. Shared by the
/// CALayer tree and the Canvas so the two cannot drift.
@available(macOS 15.0, *)
enum FigureRenderer {
    struct Stroke {
        let path: CGPath
        let width: CGFloat
        let roundCaps: Bool
    }

    struct Parts {
        let fill: CGPath?
        let strokes: [Stroke]
    }

    static func parts(for figure: LayoutFigure) -> Parts {
        let fill = CGMutablePath()
        var strokes: [Stroke] = []
        for primitive in figure.primitives {
            switch primitive {
            case let .line(from, to, width, cap):
                let path = CGMutablePath()
                path.move(to: from)
                path.addLine(to: to)
                strokes.append(Stroke(path: path, width: width, roundCaps: cap == .round))
            case let .polyline(points, width):
                guard let first = points.first else { continue }
                let path = CGMutablePath()
                path.move(to: first)
                for point in points.dropFirst() {
                    path.addLine(to: point)
                }
                strokes.append(Stroke(path: path, width: width, roundCaps: false))
            case let .ellipse(rect, isFilled, width):
                if isFilled {
                    fill.addEllipse(in: rect)
                } else {
                    let path = CGPath(ellipseIn: rect, transform: nil)
                    strokes.append(Stroke(path: path, width: width, roundCaps: false))
                }
            case let .rectOutline(rect, width):
                strokes.append(Stroke(path: CGPath(rect: rect, transform: nil), width: width, roundCaps: false))
            case let .run(run, rotation, pivot):
                guard let outline = ScoreLayerBuilder.richTextPath(runs: [run], decorations: []) else { continue }
                // Positive turns clockwise on screen, which is what a positive rotation does in this y-down space.
                let turn = CGAffineTransform(translationX: pivot.x, y: pivot.y).rotated(by: rotation)
                    .translatedBy(x: -pivot.x, y: -pivot.y)
                fill.addPath(outline, transform: rotation == 0 ? .identity : turn)
            }
        }
        return Parts(fill: fill.isEmpty ? nil : fill, strokes: strokes)
    }
}
