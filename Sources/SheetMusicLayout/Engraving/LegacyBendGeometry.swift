#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

/// The draw pieces of one legacy bend, in whatever frame the producer
/// used: note-local straight out of `LegacyBendGeometry.shape`, and
/// system-local once the layout pass has translated it.
///
/// A `LegacyBend` is a pitch CURVE rather than a two-anchor spanner, so
/// unlike `.guitarBend` it cannot be described by three points — the
/// number of legs follows the number of curve points. The geometry is
/// therefore resolved once, at layout time, and the renderer just
/// strokes what it is given.
public struct LegacyBendShape: Sendable, Equatable {
    public enum Piece: Sendable, Equatable {
        /// A straight run: the prebend riser, or a held plateau between
        /// two legs.
        case line(from: CGPoint, to: CGPoint)
        /// One rising or falling leg. C++ emits it as a single cubic
        /// (`tdraw.cpp:1004`).
        case curve(
            from: CGPoint, control1: CGPoint, control2: CGPoint, to: CGPoint,
        )
        /// Arrowhead at a leg's far end. `up` picks which way it points.
        case arrow(tip: CGPoint, up: Bool)
        /// Bend amount ("full", "1/2", …) drawn above `anchor`.
        case label(text: String, anchor: CGPoint)
    }

    public var pieces: [Piece]

    public init(pieces: [Piece]) {
        self.pieces = pieces
    }

    /// Every point of every piece shifted by `delta`. Used both by the
    /// attach pass (note-local → system-local) and by the layout's
    /// translate pass.
    public func translated(by delta: CGPoint) -> LegacyBendShape {
        func shift(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x + delta.x, y: point.y + delta.y)
        }
        return LegacyBendShape(pieces: pieces.map { piece in
            switch piece {
            case let .line(from, to):
                return .line(from: shift(from), to: shift(to))
            case let .curve(from, control1, control2, to):
                return .curve(
                    from: shift(from),
                    control1: shift(control1),
                    control2: shift(control2),
                    to: shift(to),
                )
            case let .arrow(tip, up):
                return .arrow(tip: shift(tip), up: up)
            case let .label(text, anchor):
                return .label(text: text, anchor: shift(anchor))
            }
        })
    }
}

/// Legacy-bend geometry: the polyline/curve/arrow/label pieces of
/// MuseScore's pre-4.2 bend, ported from `TDraw::draw(const Bend*)`
/// (`rendering/score/tdraw.cpp:939`). Coordinates are note-local:
/// origin at the notehead's LEFT edge horizontally and its centre
/// vertically (MuseScore's note pos frame).
///
/// The draw code — not its sibling `TLayout::layoutBend`, which computes
/// only the bbox and starts x at `noteWidth` without the 0.2 sp lead-in —
/// is authoritative for where the ink lands.
public enum LegacyBendGeometry {
    /// C++ `Sid::bendLineWidth` default (`styledef.cpp:1527`).
    public static let lineThicknessSp: CGFloat = 0.15
    /// C++ `Sid::bendArrowWidth` default (`styledef.cpp:1528`).
    public static let arrowWidthSp: CGFloat = 0.5

    /// MuseScore's label table, indexed by `(pitch + 12) / 25`
    /// (`Bend::label`, `dom/bend.cpp:37`). Index 0 (a flat segment)
    /// never labels — callers only label rising/prebend legs.
    static let labels = [
        "", "1/4", "1/2", "3/4", "full",
        "1 1/4", "1 1/2", "1 3/4", "2",
        "2 1/4", "2 1/2", "2 3/4", "3",
    ]

    static func label(forPitch pitch: Int) -> String {
        let index = (pitch + 12) / 25
        guard labels.indices.contains(index) else { return "" }
        return labels[index]
    }

    /// - Parameters:
    ///   - noteWidth: notehead advance width in points
    ///     (`GuitarBendGeometry.noteheadWidthSp * sp` at the call site).
    ///   - notePosY: the note's y below its staff's TOP LINE, clamped to
    ///     ≥ 0 by the caller (`notePos.ry() = std::max(notePos.y(), 0.0)`,
    ///     `tlayout.cpp:1265`). The rise target is `-notePosY - 2 sp`:
    ///     2 sp above the staff top, or 2 sp above the note when the
    ///     note itself sits higher.
    public static func shape(
        points: [LegacyBend.Point],
        noteWidth: CGFloat,
        notePosY: CGFloat,
        sp: CGFloat,
    ) -> LegacyBendShape {
        var pieces: [LegacyBendShape.Piece] = []
        var x = noteWidth + sp * 0.2
        var y = -sp * 0.8
        let riseY = -notePosY - sp * 2
        let n = points.count
        for pt in 0 ..< max(n - 1, 0) {
            let pitch = points[pt].pitch
            if pt == 0, pitch != 0 {
                // Prebend riser: vertical line up, arrow, label.
                pieces.append(.line(
                    from: CGPoint(x: x, y: y), to: CGPoint(x: x, y: riseY),
                ))
                pieces.append(.arrow(tip: CGPoint(x: x, y: riseY), up: true))
                pieces.append(.label(
                    text: label(forPitch: pitch), anchor: CGPoint(x: x, y: riseY),
                ))
                y = riseY
            }
            let next = points[pt + 1].pitch
            var x2 = x
            var y2 = y
            if pitch == next {
                // A held pitch. The LAST such segment is elided: MuseScore
                // breaks out rather than drawing the tail of the curve past
                // the final leg.
                if pt == n - 2 { break }
                x2 = x + sp
                pieces.append(.line(
                    from: CGPoint(x: x, y: y), to: CGPoint(x: x2, y: y2),
                ))
            } else if pitch < next {
                x2 = x + sp * 0.5
                y2 = riseY
                pieces.append(curvePiece(
                    from: CGPoint(x: x, y: y), to: CGPoint(x: x2, y: y2),
                ))
                pieces.append(.arrow(tip: CGPoint(x: x2, y: y2), up: true))
                pieces.append(.label(
                    text: label(forPitch: next), anchor: CGPoint(x: x2, y: y2),
                ))
            } else {
                x2 = x + sp * 0.5
                y2 = y + sp * 3
                pieces.append(curvePiece(
                    from: CGPoint(x: x, y: y), to: CGPoint(x: x2, y: y2),
                ))
                pieces.append(.arrow(tip: CGPoint(x: x2, y: y2), up: false))
            }
            x = x2
            y = y2
        }
        return LegacyBendShape(pieces: pieces)
    }

    /// One leg's cubic: `path.cubicTo(x + dx/2, y, x2, y + dy/4, x2, y2)`
    /// (`tdraw.cpp:1004`, same for the down leg).
    private static func curvePiece(
        from: CGPoint, to: CGPoint,
    ) -> LegacyBendShape.Piece {
        let dx = to.x - from.x
        let dy = to.y - from.y
        return .curve(
            from: from,
            control1: CGPoint(x: from.x + dx / 2, y: from.y),
            control2: CGPoint(x: to.x, y: from.y + dy / 4),
            to: to,
        )
    }
}
