import CoreGraphics
import SheetMusicCore

@available(macOS 15.0, iOS 16.0, *)
extension LayoutEngine {
    /// Compute the y extent (min/max) of every placed element across all
    /// measures of a system. Used to size the system so notes on far
    /// ledger lines, tempo glyphs, dynamics, etc. don't clip.
    static func elementYBounds(
        in measures: [LayoutMeasure],
        metrics: StaffMetrics
    ) -> (min: CGFloat, max: CGFloat) {
        var minY = CGFloat.infinity
        var maxY = -CGFloat.infinity
        // Glyph metrics are anchored at their center; extend by one sp
        // in every direction so the reported bounds cover the rendered
        // pixels, not just the anchor point.
        let glyphPad = metrics.sp
        for measure in measures {
            for el in measure.elements + measure.markers + measure.jumps {
                for p in elementYPoints(el) {
                    minY = min(minY, p - glyphPad)
                    maxY = max(maxY, p + glyphPad)
                }
            }
        }
        if !minY.isFinite { minY = 0 }
        if !maxY.isFinite { maxY = 0 }
        return (minY, maxY)
    }

    /// y values contributed by a single LayoutElement.
    static func elementYPoints(
        _ element: LayoutElement
    ) -> [CGFloat] {
        switch element {
        case .clef(_, let p),
             .keySignature(_, _, let p),
             .timeSignature(_, _, let p),
             .barLine(_, let p),
             .textMark(_, _, let p),
             .fermata(_, let p),
             .marker(_, _, let p),
             .jump(_, let p),
             .measureRepeat(_, let p),
             .measureNumber(_, let p),
             .staffName(_, let p),
             .staffText(_, let p, _, _),
             .rehearsalMark(_, let p, _, _):
            return [p.y]
        case .rest(_, let p, _, _, _):
            return [p.y]
        case .note(_, _, _, _, let p, _, _, _):
            return [p.y]
        case .chord(let notes, _, _, let so, _, _, _, _):
            var ys = notes.map(\.origin.y)
            ys.append(so.y)
            return ys
        case .beam(let from, let to, _, _):
            // fromOrigin, toOrigin, direction, level — only endpoints
            // contribute to the bbox at the primary-beam y; secondary
            // bars stack a fraction of sp away and are accounted for
            // by the generic glyphPad in elementYBounds.
            return [from.y, to.y]
        case .spannerSegment(_, let from, let to, _, _, _),
             .tieArc(let from, let to, _),
             .glissandoLine(let from, let to, _, _):
            return [from.y, to.y]
        case .arpeggioWiggle(let top, let bot, _):
            return [top.y, bot.y]
        case .tupletLabel(let from, let to, _, _, _):
            return [from.y, to.y]
        case .lyricsMelisma(let from, let to),
             .lyricHyphen(let from, let to):
            return [from.y, to.y]
        }
    }

    /// Shift lyric text and lyric hyphens by `dy`. Excludes
    /// melisma rules, which are snapped absolutely by
    /// `setMelismaAbsoluteY` after this pass.
    static func shiftLyricTextY(
        _ element: LayoutElement, dy: CGFloat
    ) -> LayoutElement {
        func bump(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x, y: p.y + dy)
        }
        switch element {
        case .textMark(let kind, let text, let p)
            where kind == .lyrics:
            return .textMark(kind: kind, text: text, origin: bump(p))
        case .lyricHyphen(let from, let to):
            return .lyricHyphen(
                fromOrigin: bump(from), toOrigin: bump(to))
        default:
            return element
        }
    }

    /// Force every `.lyricsMelisma` to `y` regardless of its
    /// originating Y. See the call site in the system-wide
    /// alignment pass for the rationale.
    static func setMelismaAbsoluteY(
        _ element: LayoutElement, y: CGFloat
    ) -> LayoutElement {
        if case .lyricsMelisma(let from, let to) = element {
            return .lyricsMelisma(
                fromOrigin: CGPoint(x: from.x, y: y),
                toOrigin: CGPoint(x: to.x, y: y))
        }
        return element
    }

    static func shiftMeasure(
        _ measure: LayoutMeasure, dy: CGFloat
    ) -> LayoutMeasure {
        LayoutMeasure(
            measureIndex: measure.measureIndex,
            origin: measure.origin,
            width: measure.width,
            elements: measure.elements.map { translate(element: $0, dy: dy) },
            markers: measure.markers.map { translate(element: $0, dy: dy) },
            jumps: measure.jumps.map { translate(element: $0, dy: dy) },
            lineBreak: measure.lineBreak,
            pageBreak: measure.pageBreak
        )
    }
}
