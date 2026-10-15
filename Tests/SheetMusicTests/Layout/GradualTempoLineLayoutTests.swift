#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicMSCX
import Testing

#if !canImport(CoreGraphics)
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

/// A gradual tempo change lays out as its own line: the label (`<beginText>`, `<continueText>` on a later system)
/// typeset in the tempo change style, a dashed 0.15 sp line from just after it, above the staff.
@Suite("Gradual tempo line in layout")
struct GradualTempoLineLayoutTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    private struct Segment {
        let from: CGPoint
        let continuesLeft: Bool
        let rich: LayoutRichText?
    }

    private static func segments(_ document: LayoutDocument) -> [Segment] {
        document.systems.flatMap(\.spanners).compactMap { element in
            guard case let .spannerSegment(.gradualTempoChange, from, _, continuesLeft, _, _, _, rich, _) = element
            else { return nil }
            return Segment(from: from, continuesLeft: continuesLeft, rich: rich)
        }
    }

    private static func contents(_ rich: LayoutRichText?) -> [LayoutRichTextRun.Content] {
        rich?.lines.flatMap(\.runs).map(\.content) ?? []
    }

    @Test("every line of the fixture lays out as a gradual tempo line; the rit. carries its bold label")
    func fixtureLaysOutGradualLines() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("tempo-gradual"))
        let document = LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 1200)
        let lines = Self.segments(document)
        // rit., accel. and the muted rall. — `<play>0</play>` silences a line, it does not hide it.
        #expect(lines.filter { !$0.continuesLeft }.count == 3)
        let rit = try #require(lines.first)
        #expect(Self.contents(rit.rich) == [.text("rit.")])
        #expect(rit.rich?.lines.first?.runs.first?.font.weight == .bold)
        #expect(lines.contains { !$0.continuesLeft && $0.rich == nil })
    }

    @Test("a later system shows the continue text")
    func continuationShowsContinueText() {
        var rit = TempoMapFixtures.ritardando(measures: 3)
        rit.beginText = "rit."
        rit.continueText = "(rit.)"
        let score = TempoMapFixtures.score(measures: 4, ramps: [(measure: 0, spanner: rit)])
        let document = LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 150)
        let lines = Self.segments(document)
        #expect(lines.contains { !$0.continuesLeft && Self.contents($0.rich) == [.text("rit.")] })
        #expect(lines.contains { $0.continuesLeft && Self.contents($0.rich) == [.text("(rit.)")] })
    }

    @Test("the dashed line starts half a space after the label, or at the start without one")
    func lineGeometry() throws {
        let metrics = StaffMetrics(staffSize: 20)
        let label = try #require(LayoutRichText.gradualTempoChangeLabel("rit.", metrics: metrics))
        let from = CGPoint(x: 20, y: 50)
        let to = CGPoint(x: 220, y: 50)
        let parts = SpannerGeometry.gradualTempoChange(from: from, to: to, label: label, sp: metrics.sp)
        #expect(abs(parts.lineStart.x - (20 + label.size.width + metrics.sp * 0.5)) < 1e-9)
        #expect(parts.lineEnd.x == to.x)
        #expect(abs(parts.lineThickness - metrics.sp * 0.15) < 1e-9)
        let bare = SpannerGeometry.gradualTempoChange(from: from, to: to, label: nil, sp: metrics.sp)
        #expect(bare.lineStart == from)
        #expect(bare.lineEnd == to)
        #expect(LayoutRichText.gradualTempoChangeLabel("", metrics: metrics) == nil)
    }

    @Test("the dash pattern is stretched over the line's length so a dash starts and ends it (tdraw.cpp:1541-1547)")
    func dashesAreDistributed() throws {
        let metrics = StaffMetrics(staffSize: 20)
        let dash = metrics.sp * SpannerGeometry.gradualTempoChangeDashSp
        let gap = metrics.sp * SpannerGeometry.gradualTempoChangeGapSp
        for width in [137.3, 200, 311.9] as [CGFloat] {
            let parts = SpannerGeometry.gradualTempoChange(
                from: CGPoint(x: 20, y: 50), to: CGPoint(x: 20 + width, y: 50), label: nil, sp: metrics.sp,
            )
            let length = parts.lineEnd.x - parts.lineStart.x
            let pattern = try #require(parts.dashPattern.count == 2 ? parts.dashPattern : nil)
            let pairs = CGFloat(Int(length / (dash + gap)))
            // n + 1 dashes and n gaps fill the line exactly; the dash keeps its length, the gap absorbs the slack.
            #expect(abs(pattern[0] - dash) < 1e-9)
            #expect(abs(pattern[0] * (pairs + 1) + pattern[1] * pairs - length) < 1e-6)
            // The undistributed pattern (`[dash, gap]` at any length) is what this test exists to rule out.
            #expect(abs(pattern[1] - gap) > 1e-6)
        }
    }

    @Test("the end label starts at the segment end (tempoChangePosition LEFT) and the line stops half a space short")
    func endLabelHangsRightOfEnd() throws {
        let metrics = StaffMetrics(staffSize: 20)
        let label = try #require(LayoutRichText.gradualTempoChangeLabel("rit.", metrics: metrics))
        let end = try #require(LayoutRichText.gradualTempoChangeLabel("a tempo", metrics: metrics))
        let from = CGPoint(x: 20, y: 50)
        let to = CGPoint(x: 220, y: 50)
        let parts = SpannerGeometry.gradualTempoChange(from: from, to: to, label: label, endLabel: end, sp: metrics.sp)
        // `tlayout.cpp:5865-5883` with AlignH::LEFT (`styledef.cpp:1186`): `l2` is only the gap, the text's left edge
        // is `max(to.x, beginRight + gap)`, so it is not right-aligned to `to.x`.
        #expect(abs((parts.endLabelOrigin?.x ?? .nan) - to.x) < 1e-9)
        #expect(abs(parts.lineEnd.x - (to.x - metrics.sp * 0.5)) < 1e-9)
        // A begin label reaching past the end pushes the end label to its right edge plus a gap.
        let short = CGPoint(x: from.x + 1, y: 50)
        let pushed = SpannerGeometry.gradualTempoChange(
            from: from, to: short, label: label, endLabel: end, sp: metrics.sp,
        )
        #expect(abs((pushed.endLabelOrigin?.x ?? .nan) - (from.x + label.size.width + metrics.sp * 0.5)) < 1e-9)
    }

    @Test("an authored end text lays out on the segment that ends the line, which stops half a space short of its end")
    func endTextIsLaidOut() throws {
        var rit = TempoMapFixtures.ritardando(measures: 2)
        rit.beginText = "rit."
        rit.endText = "a tempo"
        let score = TempoMapFixtures.score(measures: 3, ramps: [(measure: 0, spanner: rit)])
        let document = LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 600)
        let ends: [(to: CGPoint, from: CGPoint, detail: LayoutLineDetail?, rich: LayoutRichText?)] = document.systems
            .flatMap(\.spanners).compactMap { element in
                guard case let .spannerSegment(.gradualTempoChange, from, to, _, _, _, _, rich, detail) = element
                else { return nil }
                return (to, from, detail, rich)
            }
        let segment = try #require(ends.first)
        let end = try #require(segment.detail?.endRichText)
        #expect(Self.contents(end) == [.text("a tempo")])
        let sp = document.metrics.sp
        let parts = SpannerGeometry.gradualTempoChange(
            from: segment.from, to: segment.to, label: segment.rich, endLabel: end, sp: sp,
        )
        #expect(abs(parts.lineEnd.x - (segment.to.x - sp * 0.5)) < 1e-9)
        // No authored end text, no end label.
        var bare = TempoMapFixtures.ritardando(measures: 2)
        bare.beginText = "rit."
        let plain = LayoutEngine.layout(
            score: TempoMapFixtures.score(measures: 3, ramps: [(measure: 0, spanner: bare)]),
            options: ScoreViewOptions(), availableWidth: 600,
        )
        let details = plain.systems.flatMap(\.spanners).compactMap { element -> [LayoutLineDetail?]? in
            guard case let .spannerSegment(.gradualTempoChange, _, _, _, _, _, _, _, detail) = element
            else { return nil }
            return [detail]
        }
        #expect(details.count == 1)
        #expect(details.first?.first??.endRichText == nil)
    }

    @Test("the label's baseline is the segment's y and the line runs half its width above it (alignBaseLine)")
    func lineSitsOnLabelBaseline() throws {
        let metrics = StaffMetrics(staffSize: 20)
        let label = try #require(LayoutRichText.gradualTempoChangeLabel("rit.", metrics: metrics))
        let from = CGPoint(x: 20, y: 50)
        let to = CGPoint(x: 220, y: 50)
        let parts = SpannerGeometry.gradualTempoChange(from: from, to: to, label: label, sp: metrics.sp)
        let anchor = LayoutRichText.anchor(for: .gradualTempoChangeLabel)
        let runs = label.positionedRuns(at: parts.labelOrigin, anchor: anchor)
        let baseline = try #require(runs.first?.baseline.y)
        #expect(abs(baseline - from.y) < 1e-9)
        #expect(abs(parts.lineStart.y - (baseline - parts.lineThickness / 2)) < 1e-9)
        #expect(parts.lineStart.y == parts.lineEnd.y)
        // The label hangs from its left edge at `from.x`, so the line cannot cut through it vertically.
        let ink = try #require(label.inkRect(at: parts.labelOrigin, anchor: anchor))
        #expect(abs(ink.minX - from.x) < 1e-9)
        #expect(ink.minY < baseline)
        // A label-less line has no baseline to align to: it stays at the segment's y.
        let bare = SpannerGeometry.gradualTempoChange(from: from, to: to, label: nil, sp: metrics.sp)
        #expect(bare.lineStart.y == from.y)
    }

    @Test("the ink band holds the label above its baseline and the whole stroke")
    func inkBand() throws {
        let metrics = StaffMetrics(staffSize: 20)
        let label = try #require(LayoutRichText.gradualTempoChangeLabel("rit.", metrics: metrics))
        let from = CGPoint(x: 20, y: 50)
        let to = CGPoint(x: 220, y: 50)
        let parts = SpannerGeometry.gradualTempoChange(from: from, to: to, label: label, sp: metrics.sp)
        let ink = SpannerGeometry.gradualTempoChangeInk(from: from, to: to, label: label, sp: metrics.sp)
        #expect(ink.minY < from.y - parts.lineThickness)
        // The line's lower edge is the label's baseline, which is `from.y`.
        #expect(ink.maxY >= from.y - 1e-9)
        #expect(ink.minX <= from.x + 1e-9)
        #expect(ink.maxX >= to.x - 1e-9)
    }

    private static func gradualScore(visible: Bool) -> Score {
        var rit = TempoMapFixtures.ritardando(measures: 2)
        rit.beginText = "rit."
        rit.visible = visible
        return TempoMapFixtures.score(measures: 3, ramps: [(measure: 0, spanner: rit)])
    }

    @Test(
        "an invisible gradual line is not laid out, whether or not invisible elements are shown",
        arguments: [false, true],
    )
    func invisibleLineIsOmitted(showsInvisible: Bool) {
        let options = ScoreViewOptions(showsInvisibleElements: showsInvisible)
        let hiddenScore = Self.gradualScore(visible: false)
        let hidden = LayoutEngine.layout(score: hiddenScore, options: options, availableWidth: 600)
        #expect(Self.segments(hidden).isEmpty)
        #expect(hidden.systems.flatMap(\.invisibleSpanners).isEmpty)
        let shownScore = Self.gradualScore(visible: true)
        let shown = LayoutEngine.layout(score: shownScore, options: options, availableWidth: 600)
        #expect(Self.segments(shown).count == 1)
    }

    private struct Line {
        let kind: LayoutElement.SpannerKind
        let from: CGPoint
        let to: CGPoint
        let rich: LayoutRichText?
        let text: String
    }

    private static func lines(of kind: Spanner.Kind, rawType: String) -> [Line] {
        var line = Spanner(kind: kind, rawType: rawType, nextMeasuresOffset: 2)
        line.beginText = "dim."
        let score = TempoMapFixtures.score(measures: 3, ramps: [(measure: 0, spanner: line)])
        let document = LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 600)
        return document.systems.flatMap(\.spanners).compactMap { element in
            guard case let .spannerSegment(segmentKind, from, to, _, _, text, _, rich, _) = element else { return nil }
            return Line(kind: segmentKind, from: from, to: to, rich: rich, text: text)
        }
    }

    /// Since W6 Task 7 every text-line label is typeset as runs (`LayoutEngine.lineLabelRuns`), so both carry their
    /// label as rich text, and the two still share one path.
    @Test("a .textLine and an .other spanner lay out as the same text line, their label typeset")
    func plainTextLinesUnchanged() throws {
        let textLine = try #require(Self.lines(of: .textLine, rawType: "TextLine").first)
        let other = try #require(Self.lines(of: .other, rawType: "Foo").first)
        #expect(textLine.kind == .textLine)
        #expect(other.kind == .textLine)
        #expect(textLine.rich != nil)
        #expect(textLine.rich == other.rich)
        #expect(textLine.text == "dim.")
        #expect(other.text == "dim.")
        // Same path, same geometry: the kind alone does not move a plain line.
        #expect(textLine.from == other.from)
        #expect(textLine.to == other.to)
        // …and its x span is the one a gradual line over the same measures gets.
        var rit = TempoMapFixtures.ritardando(measures: 2)
        rit.beginText = "dim."
        let score = TempoMapFixtures.score(measures: 3, ramps: [(measure: 0, spanner: rit)])
        let document = LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 600)
        let gradual = try #require(Self.segments(document).first)
        #expect(abs(gradual.from.x - textLine.from.x) < 1e-9)
    }
}
