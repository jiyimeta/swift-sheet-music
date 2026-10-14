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
            guard case let .spannerSegment(.gradualTempoChange, from, _, continuesLeft, _, _, _, rich) = element
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
        #expect(parts.lineEnd == to)
        #expect(parts.dashPattern == [metrics.sp * 0.9, metrics.sp * 1.35])
        #expect(abs(parts.lineThickness - metrics.sp * 0.15) < 1e-9)
        let bare = SpannerGeometry.gradualTempoChange(from: from, to: to, label: nil, sp: metrics.sp)
        #expect(bare.lineStart == from)
        #expect(LayoutRichText.gradualTempoChangeLabel("", metrics: metrics) == nil)
    }
}
