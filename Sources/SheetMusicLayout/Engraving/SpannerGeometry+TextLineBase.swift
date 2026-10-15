#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

/// A text line drawn as MuseScore's `layoutTextLineBaseSegment` places it (`rendering/score/tlayout.cpp:5728-6030`).
public struct TextLineBaseParts: Sendable, Equatable {
    /// Top-left of the begin label (anchor `(0, 0)`), or `nil` without one.
    public let beginOrigin: CGPoint?
    /// Top-left of the end label (anchor `(0, 0)`), or `nil` without one.
    public let endOrigin: CGPoint?
    /// Each element is one polyline stroked as one path: the main line with its non-separate hooks, then each
    /// separately drawn hook.
    public let strokes: [[CGPoint]]
    public let thickness: CGFloat
    /// Dash and gap in points; empty = solid. A dotted line is `[lw, 2·lw]`.
    public let dashPattern: [CGFloat]
}

extension SpannerGeometry {
    /// `gapBetweenTextAndLine`, in spatia (`dom/textlinebase.cpp:218-220`).
    static let textLineBaseLabelGapSp: CGFloat = 0.5
    /// A `HOOK_45` slants by this fraction of its height (`tlayout.cpp:5904-5911`).
    private static let hook45Slant: CGFloat = 0.4

    /// Places a text line's begin label, line, hooks and end label between `from` and `to`. `from.y` is the segment's
    /// y: a BASELINE-aligned kind puts its labels' first baseline on it and lifts the line by half its width, a
    /// centered kind centers its labels on the line. The line starts after the begin label and a gap, stops before a
    /// gap and the end label, and an invisible line (`lineVisible == false`) keeps its labels and loses its strokes.
    public static func textLineBase(
        from: CGPoint, to: CGPoint, label: LayoutRichText?, detail: LayoutLineDetail, sp: CGFloat,
    ) -> TextLineBaseParts {
        let thickness = CGFloat(detail.lineWidthSp) * sp
        let gap = sp * textLineBaseLabelGapSp
        let endLabel = detail.endRichText
        let beginWidth = label?.size.width ?? 0
        let endWidth = endLabel?.size.width ?? 0
        let beginGap = label == nil ? 0 : beginWidth + gap
        let endGap = endLabel == nil ? 0 : endWidth + gap
        // The end text may not overlap the begin text (`tlayout.cpp:5865-5883`).
        let endRight = endLabel == nil ? to.x : max(to.x, from.x + beginWidth + endGap)
        var strokes: [[CGPoint]] = []
        if detail.lineVisible {
            // Labels and line share a baseline, accounting for the line's thickness (`alignBaseLine`).
            let hasLabel = label != nil || endLabel != nil
            let lift = hasLabel && detail.labelAlignment == .baseline ? thickness / 2 : 0
            strokes = lineStrokes(
                start: CGPoint(x: from.x + beginGap, y: from.y - lift),
                end: CGPoint(x: to.x - endGap, y: from.y - lift),
                hasBeginLabel: label != nil, detail: detail, sp: sp,
            )
        }
        return TextLineBaseParts(
            beginOrigin: label.map { labelOrigin($0, x: from.x, y: from.y, alignment: detail.labelAlignment) },
            endOrigin: endLabel.map {
                labelOrigin($0, x: endRight - endWidth, y: from.y, alignment: detail.labelAlignment)
            },
            strokes: strokes, thickness: thickness, dashPattern: dashPattern(detail, thickness: thickness, sp: sp),
        )
    }

    private static func labelOrigin(
        _ label: LayoutRichText, x: CGFloat, y: CGFloat, alignment: LabelAlignment,
    ) -> CGPoint {
        switch alignment {
        case .baseline: CGPoint(x: x, y: y - label.firstBaseline)
        case .center: CGPoint(x: x, y: y - label.size.height / 2)
        }
    }

    private static func dashPattern(_ detail: LayoutLineDetail, thickness: CGFloat, sp: CGFloat) -> [CGFloat] {
        switch detail.lineType {
        case .solid: []
        case .dashed: [CGFloat(detail.dashSp) * sp, CGFloat(detail.gapSp) * sp]
        case .dotted: [thickness, 2 * thickness]
        }
    }

    /// `ROSETTE`, `ARROW` and `ARROW_FILLED` draw no hook (`hasHook`, `tlayout.cpp:5937-5950`).
    private static func drawsHook(_ hook: Spanner.LineHookType) -> Bool {
        switch hook {
        case .hook90, .hook45, .hook90T: true
        case .none, .arrow, .arrowFilled, .rosette, .other: false
        }
    }

    /// The main polyline (the line and its hooks that share its stroke) and then each separately drawn hook, from the
    /// line's already label-adjusted ends. A T hook is always its own stroke; on a dashed or dotted line every hook
    /// is, so its dashes restart (`tlayout.cpp:5958-5981`; the dash-extension at the corner is not reproduced).
    private static func lineStrokes(
        start: CGPoint, end: CGPoint, hasBeginLabel: Bool, detail: LayoutLineDetail, sp: CGFloat,
    ) -> [[CGPoint]] {
        // Hooks point up when the line is placed below the staff (`tlayout.cpp:5898-5899`).
        let sign: CGFloat = detail.placedBelow ? -1 : 1
        let beginHeight = sign * CGFloat(detail.beginHookHeightSp) * sp
        let endHeight = sign * CGFloat(detail.endHookHeightSp) * sp
        let beginWidth = detail.beginHook == .hook45 ? abs(beginHeight * hook45Slant) : 0
        let endWidth = detail.endHook == .hook45 ? abs(endHeight * hook45Slant) : 0
        let p1 = CGPoint(x: start.x + beginWidth, y: start.y)
        let p2 = CGPoint(x: end.x - endWidth, y: end.y)
        // Don't draw backwards lines (or hooks) when the text is longer than the nominal line (`:5914-5918`).
        if hasBeginLabel, p1.x > p2.x { return [] }
        var main: [CGPoint] = []
        var separate: [[CGPoint]] = []
        let solid = detail.lineType == .solid
        if drawsHook(detail.beginHook) {
            let tip = CGPoint(x: p1.x - beginWidth, y: p1.y + beginHeight)
            if detail.beginHook == .hook90T {
                separate.append([tip, CGPoint(x: p1.x - beginWidth, y: p1.y - beginHeight)])
            } else if solid {
                main.append(tip)
            } else {
                separate.append([tip, p1])
            }
        }
        main += [p1, p2]
        if drawsHook(detail.endHook) {
            let tip = CGPoint(x: p2.x + endWidth, y: p2.y + endHeight)
            if detail.endHook == .hook90T {
                separate.append([tip, CGPoint(x: p2.x + endWidth, y: p2.y - endHeight)])
            } else if solid {
                main.append(tip)
            } else {
                separate.append([p2, tip])
            }
        }
        return [main] + separate
    }

    /// The ink of `textLineBase` as MuseScore's segment shape holds it (`tlayout.cpp:6007-6026`): each label's ink,
    /// then one box per piece of every stroke (`TextLineBaseSegment::boundingBoxOfLine`) — never one union, so the
    /// empty corner above a line and right of its label is not ink.
    static func textLineBaseInkParts(
        from: CGPoint, to: CGPoint, label: LayoutRichText?, detail: LayoutLineDetail, sp: CGFloat,
    ) -> [CGRect] {
        let parts = textLineBase(from: from, to: to, label: label, detail: detail, sp: sp)
        var rects: [CGRect] = []
        if let label, let origin = parts.beginOrigin {
            rects.append(LayoutElementShape.textRect(rich: label, origin: origin, kind: .lineLabel))
        }
        if let endLabel = detail.endRichText, let origin = parts.endOrigin {
            rects.append(LayoutElementShape.textRect(rich: endLabel, origin: origin, kind: .lineLabel))
        }
        let half = parts.thickness / 2
        for stroke in parts.strokes {
            for (start, end) in zip(stroke, stroke.dropFirst()) {
                rects.append(lineBox(start, end, half: half, dotted: detail.lineType == .dotted))
            }
        }
        return rects
    }

    /// `TextLineBaseSegment::boundingBoxOfLine` (`dom/textlinebase.cpp:79-88`): a dotted line's box grows by `half` on
    /// every side; any other line's grows by `half` perpendicular to its direction only.
    private static func lineBox(_ p1: CGPoint, _ p2: CGPoint, half: CGFloat, dotted: Bool) -> CGRect {
        let minX = min(p1.x, p2.x), maxX = max(p1.x, p2.x)
        let minY = min(p1.y, p2.y), maxY = max(p1.y, p2.y)
        let dx = p2.x - p1.x, dy = p2.y - p1.y
        let length = (dx * dx + dy * dy).squareRoot()
        if !dotted, length > 0 {
            // The perpendicular offset of the two end points: `b = (-a.y, a.x)` with `a = half · unit(p2 − p1)`.
            let bx = abs(half * dy / length), by = abs(half * dx / length)
            return CGRect(x: minX - bx, y: minY - by, width: maxX - minX + 2 * bx, height: maxY - minY + 2 * by)
        }
        return CGRect(x: minX - half, y: minY - half, width: maxX - minX + 2 * half, height: maxY - minY + 2 * half)
    }

    /// The single box around `textLineBaseInkParts`, for callers that want one rect (the system's height).
    static func textLineBaseInk(
        from: CGPoint, to: CGPoint, label: LayoutRichText?, detail: LayoutLineDetail, sp: CGFloat,
    ) -> CGRect {
        let rects = textLineBaseInkParts(from: from, to: to, label: label, detail: detail, sp: sp)
        guard let first = rects.first else { return .zero }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    /// A segment's line detail: its own, or for a hand-built one without a `lineDetail` the kind's defaults;
    /// `nil` for a kind that `TextLineBaseStyle` does not know.
    package static func resolvedLineDetail(
        kind: LayoutElement.SpannerKind, detail: LayoutLineDetail?, sp: CGFloat,
    ) -> LayoutLineDetail? {
        guard TextLineBaseStyle.style(for: kind) != nil else { return nil }
        if let detail { return detail }
        let below = switch kind {
        case .pedal, .palmMute, .letRing, .chordTextLine(.pickScrape): true
        default: false
        }
        return LayoutEngine.lineDetailDefaults(
            kind: kind, lineProperties: nil, endText: nil, placedBelow: below,
            metrics: StaffMetrics(staffSize: sp * 4),
        )
    }

    /// The ink parts of a text-line-family segment, for the skyline and the hit test; `nil` for any other kind.
    static func textLineSegmentInkParts(
        kind: LayoutElement.SpannerKind, from: CGPoint, to: CGPoint, label: LayoutRichText?,
        detail: LayoutLineDetail?, sp: CGFloat,
    ) -> [CGRect]? {
        guard let resolved = resolvedLineDetail(kind: kind, detail: detail, sp: sp) else { return nil }
        return textLineBaseInkParts(from: from, to: to, label: label, detail: resolved, sp: sp)
    }

    /// `textLineSegmentInkParts` as one box, for the system's height; `nil` for another kind or no ink.
    static func textLineSegmentInk(
        kind: LayoutElement.SpannerKind, from: CGPoint, to: CGPoint, label: LayoutRichText?,
        detail: LayoutLineDetail?, sp: CGFloat,
    ) -> CGRect? {
        guard let rects = textLineSegmentInkParts(
            kind: kind, from: from, to: to, label: label, detail: detail, sp: sp,
        ), let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }
}
