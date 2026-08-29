#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension LayoutEngine {
    /// Compute the y extent (min/max) of every placed element across all
    /// measures of a system. Used to size the system so notes on far
    /// ledger lines, tempo glyphs, dynamics, etc. don't clip.
    /// - Parameter extraElements: system-scoped elements that are not
    ///   held by any measure — the line spanners `buildSystem` lifts
    ///   into `LayoutSystem.spanners` — in the same coordinate space as
    ///   `measures`.
    static func elementYBounds(
        in measures: [LayoutMeasure],
        extraElements: [LayoutElement] = [],
        metrics: StaffMetrics,
    ) -> (min: CGFloat, max: CGFloat) {
        var minY = CGFloat.infinity
        var maxY = -CGFloat.infinity
        // Glyph metrics are anchored at their center; extend by one sp
        // in every direction so the reported bounds cover the rendered
        // pixels, not just the anchor point.
        let glyphPad = metrics.sp
        func accumulate(_ el: LayoutElement) {
            for p in elementYPoints(el, sp: metrics.sp) {
                minY = min(minY, p - glyphPad)
                maxY = max(maxY, p + glyphPad)
            }
        }
        for measure in measures {
            for el in measure.elements + measure.markers + measure.jumps {
                accumulate(el)
            }
        }
        for el in extraElements {
            accumulate(el)
        }
        if !minY.isFinite { minY = 0 }
        if !maxY.isFinite { maxY = 0 }
        return (minY, maxY)
    }

    /// y values contributed by a single LayoutElement.
    ///
    /// Pass `sp` to have `.spannerSegment` contribute its full ink band
    /// instead of just the anchor line. An ottava's label box is 2.5 sp
    /// tall and a text line's 2.2 sp, so the ±1 sp `glyphPad` in
    /// `elementYBounds` under-reserves them; a hairpin (1.4 sp) and a
    /// pedal (1.5 sp) happen to fit inside it. Callers that only want a
    /// representative Y — verse-row bucketing — leave it nil.
    static func elementYPoints(
        _ element: LayoutElement, sp: CGFloat? = nil,
    ) -> [CGFloat] {
        switch element {
        case let .clef(_, p, _),
             let .keySignature(_, _, _, _, p),
             let .timeSignature(_, _, p),
             let .barLine(_, p, _),
             let .textMark(_, _, p),
             let .fermata(_, p),
             let .breath(_, p),
             let .articulation(_, p, _),
             let .marker(_, _, p),
             let .jump(_, p),
             let .measureRepeat(_, p),
             let .multiMeasureRest(_, p),
             let .measureNumber(_, p),
             let .staffName(_, p),
             let .staffText(_, p, _, _),
             let .rehearsalMark(_, p, _, _),
             let .rest(_, p, _, _, _),
             let .note(_, _, _, _, p, _, _, _):
            return [p.y]
        case let .chord(notes, _, _, so, _, _, _, _, _, _, _):
            var ys = notes.map(\.origin.y)
            ys.append(so.y)
            return ys
        case let .graceChord(notes, _, _, so, _, _, _, _):
            var ys = notes.map(\.origin.y)
            ys.append(so.y)
            return ys
        case let .beam(from, to, _, _, _):
            // fromOrigin, toOrigin, direction, level — only endpoints
            // contribute to the bbox at the primary-beam y; secondary
            // bars stack a fraction of sp away and are accounted for
            // by the generic glyphPad in elementYBounds.
            return [from.y, to.y]
        case let .spannerSegment(kind, from, to, _, _, _):
            return spannerSegmentYPoints(
                kind: kind, from: from, to: to, sp: sp,
            )
        case let .tieArc(from, to, _),
             let .glissandoLine(from, to, _, _),
             let .lyricsMelisma(from, to),
             let .lyricHyphen(from, to),
             // Never wider than the note it serves — the outermost
             // note's own step already dominates this Y (see
             // `LedgerLinePass`), so folding it in here is harmless.
             let .ledgerLine(from, to, _):
            return [from.y, to.y]
        case let .guitarBend(from, vertex, to, _):
            // The vertex is the extreme point of both shapes — the peak
            // of an angular bend's polyline, and the slight bend's cubic
            // control point (which the curve never reaches, so this
            // over-reserves slightly rather than clipping).
            return [from.y, vertex.y, to.y]
        case let .legacyBend(shape):
            return legacyBendYPoints(shape: shape, sp: sp)
        case let .arpeggioWiggle(top, bot, _):
            return [top.y, bot.y]
        case let .chordLine(shape, origin, _):
            return chordLineYPoints(shape: shape, origin: origin)
        case let .tremoloBars(anchor, _):
            switch anchor {
            case let .single(c): return [c.y]
            case let .between(left, right): return [left.y, right.y]
            }
        case let .tupletLabel(from, to, _, _, _, _):
            return [from.y, to.y]
        case let .harmony(lh):
            return [CGFloat(lh.y)]
        }
    }

    /// Y extent of a legacy bend: every piece's own points, plus the top
    /// of each label's text box.
    ///
    /// A `.label` anchor is the leg's tip and the text sits ABOVE it, so
    /// the anchor alone under-reserves by a line. 1.5 sp ≈ the 8 pt Edwin
    /// line (`TextStyleType.bend`) at the default spatium — a conservative
    /// reservation in the same spirit as the `.guitarBend` vertex comment.
    /// Callers that pass no `sp` only want a representative Y, so they get
    /// the anchor unpadded.
    private static func legacyBendYPoints(
        shape: LegacyBendShape, sp: CGFloat?,
    ) -> [CGFloat] {
        shape.pieces.flatMap { piece -> [CGFloat] in
            switch piece {
            case let .line(from, to):
                return [from.y, to.y]
            case let .curve(from, control1, control2, to):
                return [from.y, control1.y, control2.y, to.y]
            case let .arrow(tip, _):
                return [tip.y]
            case let .label(_, anchor):
                guard let sp else { return [anchor.y] }
                return [anchor.y, anchor.y - sp * 1.5]
            }
        }
    }

    /// Y extent of a chord line. Split out of `elementYPoints` to keep
    /// that function under the 60-line body limit.
    private static func chordLineYPoints(
        shape: ChordLineShape, origin: CGPoint,
    ) -> [CGFloat] {
        switch shape {
        case let .path(segments):
            // The path can run a full spatium above / below its origin,
            // so both extremes must reach the bbox.
            let box = ChordLineGeometry.boundingBox(of: segments)
            return [origin.y + box.minY, origin.y + box.maxY]
        case .glyph:
            // Centre-anchored; the generic glyphPad in `elementYBounds`
            // covers the ink extent.
            return [origin.y]
        }
    }

    /// Y extent of a spanner segment: its full ink band when `sp` is
    /// known, otherwise just the anchor line.
    private static func spannerSegmentYPoints(
        kind: LayoutElement.SpannerKind,
        from: CGPoint, to: CGPoint, sp: CGFloat?,
    ) -> [CGFloat] {
        guard let sp else { return [from.y, to.y] }
        let half = SpannerGeometry.segmentThickness(
            kind: kind, sp: sp,
        ) / 2
        return [
            from.y - half, to.y - half,
            from.y + half, to.y + half,
        ]
    }

    /// Shift lyric text and lyric hyphens by `dy`. Excludes
    /// melisma rules, which are snapped absolutely by
    /// `setMelismaAbsoluteY` after this pass.
    static func shiftLyricTextY(
        _ element: LayoutElement, dy: CGFloat,
    ) -> LayoutElement {
        func bump(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x, y: p.y + dy)
        }
        switch element {
        case let .textMark(.lyrics(color), text, p):
            return .textMark(
                kind: .lyrics(color: color), text: text, origin: bump(p),
            )
        case let .lyricHyphen(from, to):
            return .lyricHyphen(
                fromOrigin: bump(from), toOrigin: bump(to),
            )
        default:
            return element
        }
    }

    /// Force every `.lyricsMelisma` to `y` regardless of its
    /// originating Y. See the call site in the system-wide
    /// alignment pass for the rationale.
    static func setMelismaAbsoluteY(
        _ element: LayoutElement, y: CGFloat,
    ) -> LayoutElement {
        if case let .lyricsMelisma(from, to) = element {
            return .lyricsMelisma(
                fromOrigin: CGPoint(x: from.x, y: y),
                toOrigin: CGPoint(x: to.x, y: y),
            )
        }
        return element
    }

    static func shiftMeasure(
        _ measure: LayoutMeasure, dy: CGFloat,
    ) -> LayoutMeasure {
        LayoutMeasure(
            measureIndex: measure.measureIndex,
            origin: measure.origin,
            width: measure.width,
            elements: measure.elements.map { translate(element: $0, dy: dy) },
            markers: measure.markers.map { translate(element: $0, dy: dy) },
            jumps: measure.jumps.map { translate(element: $0, dy: dy) },
            lineBreak: measure.lineBreak,
            pageBreak: measure.pageBreak,
            tickColumns: measure.tickColumns,
            multiMeasureRest: measure.multiMeasureRest,
            // Carry hidden annotations through the top-shift pass too,
            // shifted by the same dy so they stay aligned with the
            // visible content the renderer draws alongside them.
            invisibleElements: measure.invisibleElements
                .map { translate(element: $0, dy: dy) },
            // Shift chord north Y values by the same dy so vibrato
            // autoplace remains valid after a top-clip correction.
            chordNorthByTick: measure.chordNorthByTick.mapValues { $0 + dy },
            // Dynamic extents are horizontal only — a vertical shift
            // leaves them valid as-is.
            dynamicExtents: measure.dynamicExtents,
        )
    }
}
