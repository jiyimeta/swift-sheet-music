#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

/// A text line's begin label, line, hooks and end label, placed as MuseScore's `layoutTextLineBaseSegment` does.
@Suite("Text-line geometry")
struct TextLineBaseGeometryTests {
    private static let metrics = StaffMetrics(staffSize: 20)
    private static let from = CGPoint(x: 20, y: 100)
    private static let to = CGPoint(x: 220, y: 100)

    private static func label(_ xml: String) -> LayoutRichText {
        FontMetrics.$scopedProvider.withValue(StubFontMetricsProvider()) {
            LayoutRichText(RichText(xmlText: xml), style: .staffText, metrics: metrics)
        }
    }

    private static func detail(
        kind: LayoutElement.SpannerKind = .pedal, below: Bool = true,
        _ configure: (inout LayoutLineDetail) -> Void = { _ in },
    ) -> LayoutLineDetail {
        guard var detail = LayoutEngine.lineDetailDefaults(
            kind: kind, lineProperties: nil, endText: nil, placedBelow: below, metrics: metrics,
        ) else {
            Issue.record("no line detail for \(kind)")
            return LayoutLineDetail()
        }
        configure(&detail)
        return detail
    }

    private static func parts(
        label: LayoutRichText? = nil, detail: LayoutLineDetail, to end: CGPoint = Self.to,
    ) -> TextLineBaseParts {
        SpannerGeometry.textLineBase(from: from, to: end, label: label, detail: detail, sp: metrics.sp)
    }

    @Test("no label: the line runs from to to, centered, at the kind's width")
    func bareLine() {
        let parts = Self.parts(detail: Self.detail())
        #expect(parts.strokes.map(\.points) == [[Self.from, Self.to]])
        #expect(abs(parts.thickness - Self.metrics.sp * 0.11) < 1e-9)
        #expect(parts.beginOrigin == nil)
    }

    @Test("a begin label pushes the line half a space past its width; baseline kinds lift the line by half its width")
    func pedalVariantsGeometry() throws {
        let ped = Self.label("<sym>keyboardPedalPed</sym>")
        let parts = Self.parts(label: ped, detail: Self.detail())
        // `#require`, not `strokes[0]`: the red run has no strokes and an index would trap instead of failing.
        let line = try #require(parts.strokes.first?.points)
        try #require(line.count == 2)
        #expect(abs(line[0].x - (Self.from.x + ped.size.width + Self.metrics.sp * 0.5)) < 1e-9)
        #expect(abs(line[0].y - (Self.from.y - parts.thickness / 2)) < 1e-9)
        #expect(abs((parts.beginOrigin?.y ?? 0) - (Self.from.y - ped.firstBaseline)) < 1e-9)
    }

    @Test("a centered kind keeps the line on y and centers the label on it")
    func centeredKind() {
        let words = Self.label("let ring")
        let parts = Self.parts(label: words, detail: Self.detail(kind: .letRing, below: true))
        #expect(parts.strokes.first?.points.first?.y == Self.from.y)
        #expect(abs((parts.beginOrigin?.y ?? 0) - (Self.from.y - words.size.height / 2)) < 1e-9)
    }

    @Test("the end label starts at the segment end (AlignH::LEFT) and the line stops half a space short of it")
    func endLabel() {
        let star = Self.label("<sym>keyboardPedalUp</sym>")
        var detail = Self.detail()
        detail.endRichText = star
        let parts = Self.parts(detail: detail)
        // `tlayout.cpp:5865-5883`: every kind's end text position is LEFT, so `l2` is only the gap and the text's LEFT
        // edge is `max(pp2.x, shapeRight + l2)` — it hangs right of `to.x`, it is not right-aligned to it.
        #expect(abs((parts.endOrigin?.x ?? .nan) - Self.to.x) < 1e-9)
        let lineEnd = parts.strokes.first?.points.last?.x ?? .nan
        #expect(abs(lineEnd - (Self.to.x - Self.metrics.sp * 0.5)) < 1e-9)
    }

    @Test("a begin label wider than the line pushes the end label right of its box plus a gap")
    func endLabelClearsBeginLabel() {
        let wide = Self.label("a very long beginning text for a very short line")
        let star = Self.label("<sym>keyboardPedalUp</sym>")
        var detail = Self.detail { $0.lineVisible = false }
        detail.endRichText = star
        let shortTo = CGPoint(x: Self.from.x + 10, y: Self.from.y)
        let parts = Self.parts(label: wide, detail: detail, to: shortTo)
        let expected = Self.from.x + wide.size.width + Self.metrics.sp * 0.5
        #expect(expected > shortTo.x)
        #expect(abs((parts.endOrigin?.x ?? .nan) - expected) < 1e-9)
    }

    @Test("hooks: 90 is vertical, up when placed below; 45 slants by 0.4 and shortens the line; 90T is a separate T")
    func hooks() {
        let sp = Self.metrics.sp
        var parts = Self.parts(detail: Self.detail { $0.endHook = .hook90 })
        // (no label, so no baseline lift: the hook hangs from the unlifted line end)
        #expect(parts.strokes.first?.points.last == CGPoint(x: Self.to.x, y: Self.from.y - 1.2 * sp))
        parts = Self.parts(detail: Self.detail { $0.endHook = .hook45 })
        let slant = 1.2 * sp * 0.4
        let line45 = parts.strokes.first?.points ?? []
        #expect(line45.count == 3)
        #expect(abs((line45.count > 1 ? line45[1].x : .nan) - (Self.to.x - slant)) < 1e-9)
        #expect(abs((line45.last?.x ?? .nan) - Self.to.x) < 1e-9)
        parts = Self.parts(detail: Self.detail(kind: .letRing, below: false) { $0.endHook = .hook90T })
        #expect(parts.strokes.count == 2)
        #expect(parts.strokes.dropFirst().first?.points
            == [CGPoint(x: Self.to.x, y: Self.from.y + 0.6 * sp), CGPoint(x: Self.to.x, y: Self.from.y - 0.6 * sp)])
        // Above the staff the hook points down; rosette and arrows draw no hook.
        parts = Self.parts(detail: Self.detail { $0.endHook = .rosette })
        #expect(parts.strokes.map(\.points) == [[Self.from, Self.to]])
    }

    @Test("an invisible line keeps its labels and draws no stroke")
    func invisibleLine() {
        let ped = Self.label("<sym>keyboardPedalPed</sym>")
        let parts = Self.parts(label: ped, detail: Self.detail {
            $0.lineVisible = false
            $0.endHook = .rosette
        })
        #expect(parts.strokes.isEmpty)
        #expect(parts.beginOrigin != nil)
    }

    /// Compared with a tolerance: `dashSp` is already ×lineWidth, so its rounding differs from this product's.
    private static func same(_ actual: [CGFloat], _ expected: [CGFloat]) -> Bool {
        actual.count == expected.count && zip(actual, expected).filter { abs($0 - $1) > 1e-9 }.isEmpty
    }

    private static func length(_ points: [CGPoint]) -> CGFloat {
        guard let first = points.first, let last = points.last else { return 0 }
        return ((last.x - first.x) * (last.x - first.x) + (last.y - first.y) * (last.y - first.y)).squareRoot()
    }

    @Test("a dashed main line's pattern is stretched so a dash starts and ends it (distributedDashPattern)")
    func dashedMainLineDistribution() throws {
        let sp = Self.metrics.sp
        // `tdraw.cpp:1541-1547`: numPairs = Int(length / (dash + gap)); gap' = (length - dash·(n+1)) / n.
        let parts = Self.parts(detail: Self.detail(kind: .letRing))
        let main = try #require(parts.strokes.first)
        let dash = 5 * sp * 0.11
        let length = Self.length(main.points)
        let pairs = max(1, Int(length / (dash + dash)))
        try #require(main.dashPattern.count == 2)
        #expect(abs(main.dashPattern[0] - dash) < 1e-9)
        let sum = main.dashPattern[0] * CGFloat(pairs + 1) + main.dashPattern[1] * CGFloat(pairs)
        #expect(abs(sum - length) < 1e-6)
        #expect(!main.roundCap)
    }

    @Test("a T hook on a dashed line is drawn solid; a plain hook gets its own distributed pattern")
    func teeHookIsSolid() throws {
        let sp = Self.metrics.sp
        let tee = Self.parts(detail: Self.detail(kind: .letRing, below: false) { $0.endHook = .hook90T })
        try #require(tee.strokes.count == 2)
        #expect(!tee.strokes[0].dashPattern.isEmpty)
        #expect(tee.strokes[1].dashPattern.isEmpty)
        // A 3 sp hook (15 pt) holds two dash pairs, so the distribution is not the degenerate one.
        let hooked = Self.parts(detail: Self.detail(kind: .letRing, below: false) {
            $0.endHook = .hook90
            $0.endHookHeightSp = 3
        })
        try #require(hooked.strokes.count == 2)
        let hook = hooked.strokes[1]
        let hookLength = Self.length(hook.points)
        #expect(abs(hookLength - 3 * sp) < 1e-9)
        try #require(hook.dashPattern.count == 2)
        let dash = 5 * sp * 0.11
        let pairs = max(1, Int(hookLength / (dash + dash)))
        let sum = hook.dashPattern[0] * CGFloat(pairs + 1) + hook.dashPattern[1] * CGFloat(pairs)
        #expect(pairs == 2)
        #expect(abs(sum - hookLength) < 1e-6)
    }

    @Test("dotted is a 0.01 line-width dash and a 1.99 gap with round caps; solid has none")
    func dotted() throws {
        let sp = Self.metrics.sp
        let lw = sp * 0.11
        // `setDashAndGapLen`, `tdraw.cpp:1524-1538`: the dash 0.01 and gap 1.99 (in line widths) keep a 2·lw period.
        let parts = Self.parts(detail: Self.detail { $0.lineType = .dotted })
        let stroke = try #require(parts.strokes.first)
        #expect(stroke.roundCap)
        try #require(stroke.dashPattern.count == 2)
        #expect(abs(stroke.dashPattern[0] - 0.01 * lw) < 1e-9)
        let length = Self.length(stroke.points)
        let pairs = max(1, Int(length / (2 * lw)))
        let sum = stroke.dashPattern[0] * CGFloat(pairs + 1) + stroke.dashPattern[1] * CGFloat(pairs)
        #expect(abs(sum - length) < 1e-6)
        // The gap stays within one dot of 1.99·lw: round dots on a two-line-width period.
        #expect(abs(stroke.dashPattern[1] - 1.99 * lw) < lw)
        let solid = Self.parts(detail: Self.detail(kind: .textLine, below: false))
        #expect(solid.strokes.allSatisfy { $0.dashPattern.isEmpty && !$0.roundCap })
    }

    @Test("a hand-built hairpin line is placed below by default, like the pedal (hairpinPlacement BELOW)")
    func hairpinLineDefaultsBelow() {
        for crescendo in [true, false] {
            let detail = SpannerGeometry.resolvedLineDetail(
                kind: .hairpinLine(crescendo: crescendo), detail: nil, sp: Self.metrics.sp,
            )
            #expect(detail?.placedBelow == true)
        }
    }

    @Test("a begin label longer than the line draws no line and no hook")
    func labelLongerThanLine() {
        let wide = Self.label("a very long beginning text for a very short line")
        let parts = Self.parts(
            label: wide, detail: Self.detail { $0.endHook = .hook90 },
            to: CGPoint(x: Self.from.x + 10, y: Self.from.y),
        )
        #expect(parts.strokes.isEmpty)
        #expect(parts.beginOrigin != nil)
    }

    @Test("the ink is one part per label and per stroke piece; the corner above the line is no part")
    func inkParts() throws {
        let ped = Self.label("<sym>keyboardPedalPed</sym>")
        let sp = Self.metrics.sp
        let detail = Self.detail { $0.endHook = .hook90 }
        let parts = SpannerGeometry.textLineBaseInkParts(
            from: Self.from, to: Self.to, label: ped, detail: detail, sp: sp,
        )
        // The label, the line, and the hook's vertical piece (the polyline's last stroke).
        #expect(parts.count >= 3)
        let label = try #require(parts.first)
        let corner = CGPoint(x: (label.maxX + Self.to.x) / 2, y: label.minY + 0.5)
        #expect(parts.filter { $0.contains(corner) }.isEmpty)
        // A horizontal line's box grows by half its width across the line only, not along it.
        let thickness = CGFloat(detail.lineWidthSp) * sp
        let line = try #require(parts.dropFirst().first)
        #expect(abs(line.height - thickness) < 1e-9)
    }

    @Test("a piece shorter than two dashes gets one dash and no gap; the pattern is never negative")
    func negativeGapIsClamped() {
        // MuseScore's formula `(length - dash * (numPairs + 1)) / numPairs` goes negative here: numPairs is 1 and the
        // piece is shorter than two dashes (`tdraw.cpp:1541-1547`).
        for length in [0, 1, 5, 9.5] as [CGFloat] {
            let pattern = SpannerGeometry.distributedDashPattern(dash: 6, gap: 9, length: length)
            #expect(pattern == [6, 0])
        }
        // At exactly two dashes the formula gives a zero gap by itself, and a longer piece a positive one.
        #expect(SpannerGeometry.distributedDashPattern(dash: 6, gap: 9, length: 12) == [6, 0])
        let longer = SpannerGeometry.distributedDashPattern(dash: 6, gap: 9, length: 40)
        #expect(longer.count == 2 && longer[0] == 6 && longer[1] > 0)
        #expect(longer.filter { $0 < 0 }.isEmpty)
    }

    @Test("the ink is the labels' ink and the stroke, expanded by half the width")
    func ink() {
        let ped = Self.label("<sym>keyboardPedalPed</sym>")
        let ink = SpannerGeometry.textLineBaseInk(
            from: Self.from, to: Self.to, label: ped, detail: Self.detail(), sp: Self.metrics.sp,
        )
        #expect(ink.maxX >= Self.to.x)
        #expect(ink.minX <= Self.from.x + ped.size.width)
        #expect(ink.height > 0)
    }
}
