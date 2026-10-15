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
        #expect(parts.strokes == [[Self.from, Self.to]])
        #expect(abs(parts.thickness - Self.metrics.sp * 0.11) < 1e-9)
        #expect(parts.beginOrigin == nil)
    }

    @Test("a begin label pushes the line half a space past its width; baseline kinds lift the line by half its width")
    func pedalVariantsGeometry() throws {
        let ped = Self.label("<sym>keyboardPedalPed</sym>")
        let parts = Self.parts(label: ped, detail: Self.detail())
        // `#require`, not `strokes[0]`: the red run has no strokes and an index would trap instead of failing.
        let line = try #require(parts.strokes.first)
        try #require(line.count == 2)
        #expect(abs(line[0].x - (Self.from.x + ped.size.width + Self.metrics.sp * 0.5)) < 1e-9)
        #expect(abs(line[0].y - (Self.from.y - parts.thickness / 2)) < 1e-9)
        #expect(abs((parts.beginOrigin?.y ?? 0) - (Self.from.y - ped.firstBaseline)) < 1e-9)
    }

    @Test("a centered kind keeps the line on y and centers the label on it")
    func centeredKind() {
        let words = Self.label("let ring")
        let parts = Self.parts(label: words, detail: Self.detail(kind: .letRing, below: true))
        #expect(parts.strokes.first?.first?.y == Self.from.y)
        #expect(abs((parts.beginOrigin?.y ?? 0) - (Self.from.y - words.size.height / 2)) < 1e-9)
    }

    @Test("the end label is right-aligned to the segment end and the line stops half a space short of it")
    func endLabel() {
        let star = Self.label("<sym>keyboardPedalUp</sym>")
        var detail = Self.detail()
        detail.endRichText = star
        let parts = Self.parts(detail: detail)
        #expect(abs((parts.endOrigin?.x ?? 0) - (Self.to.x - star.size.width)) < 1e-9)
        let lineEnd = parts.strokes.first?.last?.x ?? .nan
        #expect(abs(lineEnd - (Self.to.x - star.size.width - Self.metrics.sp * 0.5)) < 1e-9)
    }

    @Test("hooks: 90 is vertical, up when placed below; 45 slants by 0.4 and shortens the line; 90T is a separate T")
    func hooks() {
        let sp = Self.metrics.sp
        var parts = Self.parts(detail: Self.detail { $0.endHook = .hook90 })
        // (no label, so no baseline lift: the hook hangs from the unlifted line end)
        #expect(parts.strokes.first?.last == CGPoint(x: Self.to.x, y: Self.from.y - 1.2 * sp))
        parts = Self.parts(detail: Self.detail { $0.endHook = .hook45 })
        let slant = 1.2 * sp * 0.4
        let line45 = parts.strokes.first ?? []
        #expect(line45.count == 3)
        #expect(abs((line45.count > 1 ? line45[1].x : .nan) - (Self.to.x - slant)) < 1e-9)
        #expect(abs((line45.last?.x ?? .nan) - Self.to.x) < 1e-9)
        parts = Self.parts(detail: Self.detail(kind: .letRing, below: false) { $0.endHook = .hook90T })
        #expect(parts.strokes.count == 2)
        #expect(parts.strokes.dropFirst().first
            == [CGPoint(x: Self.to.x, y: Self.from.y + 0.6 * sp), CGPoint(x: Self.to.x, y: Self.from.y - 0.6 * sp)])
        // Above the staff the hook points down; rosette and arrows draw no hook.
        parts = Self.parts(detail: Self.detail { $0.endHook = .rosette })
        #expect(parts.strokes == [[Self.from, Self.to]])
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

    @Test("dashed and dotted lines distribute the style's dash and gap in line widths")
    func dashes() {
        let sp = Self.metrics.sp
        /// Compared with a tolerance: `dashSp` is already ×lineWidth, so its rounding differs from this product's.
        func same(_ actual: [CGFloat], _ expected: [CGFloat]) -> Bool {
            actual.count == expected.count && zip(actual, expected).filter { abs($0 - $1) > 1e-9 }.isEmpty
        }
        var parts = Self.parts(detail: Self.detail(kind: .letRing))
        #expect(same(parts.dashPattern, [5 * sp * 0.11, 5 * sp * 0.11]))
        parts = Self.parts(detail: Self.detail { $0.lineType = .dotted })
        #expect(same(parts.dashPattern, [sp * 0.11, 2 * sp * 0.11]))
        parts = Self.parts(detail: Self.detail(kind: .textLine, below: false))
        #expect(parts.dashPattern.isEmpty)
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
