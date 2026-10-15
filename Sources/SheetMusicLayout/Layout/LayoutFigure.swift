#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
import SheetMusicFoundation

/// What a non-text annotation draws — ambitus, figured bass, fret diagrams, circled string numbers and `<Symbol>`s:
/// strokes, ellipses and glyph / text runs, in measure-local points.
public struct LayoutFigure: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case symbol, ambitus, figuredBass, fretDiagram, stringNumber

        /// How the skyline sees it: a symbol not at all (MuseScore neither autoplaces a segment's symbol nor lets it
        /// widen the segment, `dom/segment.cpp:2682-2683`); an ambitus as the header element it is; figured bass and
        /// a string number as a fixed obstacle (their placement says `autoplace: false`); a fret diagram with the chord
        /// symbols it is laid out among.
        var shapeKind: ShapeItemKind? {
            switch self {
            case .symbol: nil
            case .ambitus: .keySignature
            case .figuredBass, .stringNumber: .staffText
            case .fretDiagram: .harmony
            }
        }
    }

    public enum Cap: Sendable, Equatable {
        case flat, round
    }

    public enum Primitive: Sendable, Equatable {
        case line(from: CGPoint, to: CGPoint, width: CGFloat, cap: Cap)
        case polyline(points: [CGPoint], width: CGFloat)
        /// A filled ellipse, or one stroked at `width`.
        case ellipse(rect: CGRect, fill: Bool, width: CGFloat)
        case rectOutline(rect: CGRect, width: CGFloat)
        /// A glyph or text run, turned by `rotation` radians (clockwise on screen) about `pivot`.
        case run(LayoutRichTextPositionedRun, rotation: CGFloat, pivot: CGPoint)
    }

    public let primitives: [Primitive]
    /// The union of everything drawn, strokes with their width and a turned run's ink turned with it; `.zero` for
    /// nothing.
    public let ink: CGRect

    init(primitives: [Primitive]) {
        self.primitives = primitives
        ink = primitives.compactMap(Self.ink(of:)).reduce(nil) { $0?.union($1) ?? $1 } ?? .zero
    }

    private init(primitives: [Primitive], ink: CGRect) {
        self.primitives = primitives
        self.ink = ink
    }

    /// Everything moved by (`dx`, `dy`), runs and their pivots included.
    public func translated(dx: CGFloat, dy: CGFloat) -> LayoutFigure {
        func moved(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x + dx, y: point.y + dy)
        }
        let primitives = primitives.map { primitive -> Primitive in
            switch primitive {
            case let .line(from, to, width, cap):
                .line(from: moved(from), to: moved(to), width: width, cap: cap)
            case let .polyline(points, width):
                .polyline(points: points.map(moved), width: width)
            case let .ellipse(rect, fill, width):
                .ellipse(rect: rect.offsetBy(dx: dx, dy: dy), fill: fill, width: width)
            case let .rectOutline(rect, width):
                .rectOutline(rect: rect.offsetBy(dx: dx, dy: dy), width: width)
            case let .run(run, rotation, pivot):
                .run(
                    LayoutRichTextPositionedRun(content: run.content, font: run.font, baseline: moved(run.baseline)),
                    rotation: rotation, pivot: moved(pivot),
                )
            }
        }
        return LayoutFigure(primitives: primitives, ink: ink.offsetBy(dx: dx, dy: dy))
    }

    private static func ink(of primitive: Primitive) -> CGRect? {
        switch primitive {
        case let .line(from, to, width, _):
            bounds(of: [from, to])?.insetBy(dx: -width / 2, dy: -width / 2)
        case let .polyline(points, width):
            bounds(of: points)?.insetBy(dx: -width / 2, dy: -width / 2)
        case let .ellipse(rect, fill, width):
            fill ? rect : rect.insetBy(dx: -width / 2, dy: -width / 2)
        case let .rectOutline(rect, width):
            rect.insetBy(dx: -width / 2, dy: -width / 2)
        case let .run(run, rotation, pivot):
            runInk(run).map { rotation == 0 ? $0 : rotated($0, by: rotation, about: pivot) }
        }
    }

    /// The run's glyph / text ink, page-oriented: the provider's box is Y-up from the baseline.
    private static func runInk(_ run: LayoutRichTextPositionedRun) -> CGRect? {
        guard let box = FontMetrics.provider.textInkBounds(text: run.content.string, font: run.font) else {
            return nil
        }
        return CGRect(x: run.baseline.x + box.minX, y: run.baseline.y - box.maxY, width: box.width, height: box.height)
    }

    /// The bounds of `rect`'s corners turned by `angle` radians — clockwise on screen in this y-down space — about
    /// `pivot`.
    private static func rotated(_ rect: CGRect, by angle: CGFloat, about pivot: CGPoint) -> CGRect {
        let cosine = cos(angle)
        let sine = sin(angle)
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
        ].map { corner in
            let x = corner.x - pivot.x
            let y = corner.y - pivot.y
            return CGPoint(x: pivot.x + x * cosine - y * sine, y: pivot.y + x * sine + y * cosine)
        }
        return bounds(of: corners) ?? rect
    }

    private static func bounds(of points: [CGPoint]) -> CGRect? {
        guard let first = points.first else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
