import SheetMusicCore
import SheetMusicLayout

/// A rectangle in document millimetres, Y down — the draw program's own space.
public struct DrawRect: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double {
        x + width
    }

    public var maxY: Double {
        y + height
    }

    /// The smallest rectangle holding both.
    public func union(_ other: DrawRect) -> DrawRect {
        let minX = min(x, other.x)
        let minY = min(y, other.y)
        return DrawRect(x: minX, y: minY, width: max(maxX, other.maxX) - minX, height: max(maxY, other.maxY) - minY)
    }

    /// Whether the two overlap (touching edges do not).
    public func intersects(_ other: DrawRect) -> Bool {
        x < other.maxX && other.x < maxX && y < other.maxY && other.y < maxY
    }

    func insetBy(_ amount: Double) -> DrawRect {
        DrawRect(x: x + amount, y: y + amount, width: width - 2 * amount, height: height - 2 * amount)
    }
}

/// One system's run of a page's commands — or the title block's — and the part of the page those commands can paint.
///
/// `LayoutBridge.buildCommands` walks the systems in order and emits everything a system draws (staff lines, measure
/// elements, system spanners, the system start, invisible elements) inside that system's iteration, so a system's
/// commands are one contiguous range. A renderer that caches the page in pieces (the Windows onscreen surface
/// rasterizes horizontal bands) walks only the spans whose `frameMM` crosses a piece. That is correct because every
/// state command (color, dash, rotation, text style) is set and reset within the element that needs it: a walk that
/// starts at a span's first command from the default state paints what the full walk paints there.
public struct SystemSpan: Sendable, Equatable {
    /// The system's index in the laid-out document, or nil for the title block.
    public var systemIndex: Int?
    /// The span's commands, as indices into its page's `commands`.
    public var commandRange: Range<Int>
    /// The system's frame joined with a conservative bound of every command in the span — spanners (slurs, ottava
    /// lines, tuplet brackets) can paint outside the system's own frame, and a piece that only crosses that overhang
    /// still has to draw it.
    public var frameMM: DrawRect

    public init(systemIndex: Int?, commandRange: Range<Int>, frameMM: DrawRect) {
        self.systemIndex = systemIndex
        self.commandRange = commandRange
        self.frameMM = frameMM
    }
}

/// Everything `LayoutBridge.computePages` produces: the pages as commands, each page's spans, and the layout they came
/// from.
public struct LayoutPages: Sendable {
    /// The full layout — in `.page` mode the continuous one, as `computeWithDocument` returns it.
    public var document: LayoutDocument
    public var pages: [EncodablePage]
    /// `spans[i]` belongs to `pages[i]`: in command order, covering its commands exactly.
    public var spans: [[SystemSpan]]
    /// The score the layout was built from, with clef overrides, transposition and hidden staves applied.
    public var filteredScore: Score
}

/// Conservative paint bounds of draw commands, in the commands' millimetres. `package` for the Windows renderer, which
/// culls commands a band cannot show with it.
///
/// Conservative, not exact: glyph and text extents come from their size rather than from the font, so a bound is
/// larger than the ink. Too large costs a renderer an unneeded walk; too small would clip ink at a piece's edge.
package struct DrawCommandBounds {
    /// SMuFL glyphs are drawn at a font size of four staff spaces (one em). The widest single glyphs used here
    /// (ornaments, dynamics, clefs) stay within these multiples of the size around their origin.
    private static let glyphLeft = 0.5
    private static let glyphRight = 3.0
    private static let glyphUp = 1.5
    private static let glyphDown = 1.5
    /// Strokes are drawn at a minimum of 1.5 px, which is under 1 mm at any zoom the readers use.
    private static let strokeMargin = 1.0

    private var rotation: (radians: Double, pivotX: Double, pivotY: Double) = (0, 0, 0)
    package private(set) var bounds: DrawRect?

    package init() {}

    package mutating func add(_ command: DrawCommand) {
        switch command {
        case let .moveTo(x, y), let .lineTo(x, y):
            include(point: (x, y), margin: Self.strokeMargin)
        case let .cubicTo(cx1, cy1, cx2, cy2, x, y):
            // A cubic lies inside the hull of its control points.
            include(point: (cx1, cy1), margin: Self.strokeMargin)
            include(point: (cx2, cy2), margin: Self.strokeMargin)
            include(point: (x, y), margin: Self.strokeMargin)
        case .stroke, .setColor, .setDash, .setTextStyle:
            break
        case let .fillRect(x, y, w, h):
            include(DrawRect(x: min(x, x + w), y: min(y, y + h), width: abs(w), height: abs(h)))
        case let .glyph(_, x, y, size, _):
            include(DrawRect(
                x: x - Self.glyphLeft * size,
                y: y - Self.glyphUp * size,
                width: (Self.glyphLeft + Self.glyphRight) * size,
                height: (Self.glyphUp + Self.glyphDown) * size,
            ))
        case let .stretchedGlyph(_, rightEdgeX, topY, bottomY, fontSize, xScale, _):
            let width = Self.glyphRight * fontSize * max(xScale, 1)
            include(DrawRect(
                x: rightEdgeX - width, y: min(topY, bottomY), width: width, height: abs(bottomY - topY),
            ).insetBy(-Self.strokeMargin))
        case let .text(text, x, y, size, _), let .italicText(text, x, y, size, _):
            let length = Double(max(text.count, 1))
            include(DrawRect(x: x - size, y: y - 1.5 * size, width: size * (length + 1), height: 2.25 * size))
        case let .setRotation(radians, pivotX, pivotY):
            rotation = (radians, pivotX, pivotY)
        }
    }

    private mutating func include(point: (x: Double, y: Double), margin: Double) {
        include(DrawRect(x: point.x - margin, y: point.y - margin, width: 2 * margin, height: 2 * margin))
    }

    /// Joins `rect` — as painted, so under the current rotation: the square around the pivot that holds the rectangle
    /// whatever the angle.
    private mutating func include(_ rect: DrawRect) {
        var painted = rect
        if rotation.radians != 0 {
            var radius = 0.0
            for (x, y) in [(rect.x, rect.y), (rect.maxX, rect.y), (rect.x, rect.maxY), (rect.maxX, rect.maxY)] {
                let dx: Double = x - rotation.pivotX
                let dy: Double = y - rotation.pivotY
                radius = max(radius, (dx * dx + dy * dy).squareRoot())
            }
            painted = DrawRect(
                x: rotation.pivotX - radius, y: rotation.pivotY - radius, width: 2 * radius, height: 2 * radius,
            )
        }
        bounds = bounds.map { $0.union(painted) } ?? painted
    }
}
