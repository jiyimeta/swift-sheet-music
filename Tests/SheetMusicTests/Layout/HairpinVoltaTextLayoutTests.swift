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

/// F6.5 / F6.6: a hairpin line and a wedge draw their `<beginText>`; a volta draws its authored text, in MuseScore's
/// style.
@Suite("Hairpin and volta text")
struct HairpinVoltaTextLayoutTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    private static func segments() throws -> [LayoutElement] {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("line-texts"))
        return LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 1400)
            .systems.flatMap(\.spanners)
    }

    private static func words(_ rich: LayoutRichText?) -> String {
        (rich?.lines.flatMap(\.runs).map(\.content.string) ?? []).joined()
    }

    @Test("a cresc. line with a custom text draws it, in italic")
    func hairpinLineWords() throws {
        let rich = try #require(try Self.segments().compactMap { element -> LayoutRichText? in
            if case let .spannerSegment(.hairpinLine, _, _, false, _, _, _, rich, _) = element { return rich }
            return nil
        }.first)
        #expect(Self.words(rich) == "poco a poco cresc.")
        #expect(rich.lines.first?.runs.first?.font.isItalic == true)
    }

    @Test("a wedge with text draws it and the wedge starts after it")
    func wedgeText() throws {
        let wedge = try #require(try Self.segments().compactMap { element -> (LayoutRichText?, CGPoint, CGPoint)? in
            if case let .spannerSegment(.hairpinOpen, from, to, _, _, _, _, rich, _) = element, rich != nil {
                return (rich, from, to)
            }
            return nil
        }.first)
        #expect(Self.words(wedge.0) == "cresc.")
        let shift = SpannerGeometry.wedgeTextShift(begin: wedge.0, end: nil, sp: StaffMetrics(staffSize: 20).sp)
        #expect(shift.startShift > 0)
        #expect(shift.endShift == 0)
    }

    @Test("a volta draws its authored text, bold; one without keeps the synthesized endings")
    func voltaWords() throws {
        let voltas = try Self.segments().compactMap { element -> (String, Bool)? in
            if case let .spannerSegment(.volta, _, _, false, _, _, _, rich, _) = element {
                return (Self.words(rich), rich?.lines.first?.runs.first?.font.weight == .bold)
            }
            return nil
        }
        #expect(voltas.contains { $0.0 == "Last time" && $0.1 })
        #expect(voltas.contains { $0.0 == "3." && $0.1 })
    }

    /// The metrics `segments()` lays the fixture out at, which its labels are typeset for.
    private static let metrics = StaffMetrics(staffSize: ScoreViewOptions().staffSize)

    /// A volta segment that starts its volta, with the label it carries.
    private typealias Volta = (element: LayoutElement, from: CGPoint, to: CGPoint, label: LayoutRichText)

    /// Each volta segment that starts its volta.
    private static func voltas() throws -> [Volta] {
        try segments().compactMap { element in
            guard case let .spannerSegment(.volta, from, to, false, _, _, _, rich?, _) = element else { return nil }
            return (element, from, to, rich)
        }
    }

    @Test("a volta's label hangs on its baseline 2.2 sp under the bracket, 0.6 sp in (voltaOffset, voltaAlign)")
    func voltaLabelBaseline() throws {
        let sp = Self.metrics.sp
        let label = try #require(try Self.voltas().first?.label)
        let origin = SpannerGeometry.voltaLabelOrigin(
            from: CGPoint(x: 50, y: 40), to: CGPoint(x: 150, y: 40), label: label, sp: sp,
        )
        #expect(abs(origin.x - (50 + 0.6 * sp)) < 1e-9)
        #expect(abs(origin.y + label.firstBaseline - (40 + 2.2 * sp)) < 1e-9)
    }

    @Test("a volta's label sits wholly under its bracket line instead of being struck through by it")
    func voltaLabelClearsItsLine() throws {
        let sp = Self.metrics.sp
        let voltas = try Self.voltas()
        #expect(voltas.count == 2)
        for volta in voltas {
            let origin = SpannerGeometry.voltaLabelOrigin(from: volta.from, to: volta.to, label: volta.label, sp: sp)
            let ink = try #require(volta.label.inkRect(at: origin, anchor: LayoutRichText.anchor(for: .lineLabel)))
            let lineBottom = min(volta.from.y, volta.to.y) + SpannerGeometry.strokeThicknessSp * sp / 2
            #expect(ink.minY > lineBottom)
        }
    }

    @Test("a volta's hooks drop 2.2 sp (voltaHook)")
    func voltaHooks() {
        let sp = Self.metrics.sp
        let points = SpannerGeometry.voltaBracketPoints(
            from: CGPoint(x: 50, y: 40), to: CGPoint(x: 150, y: 40), continuesLeft: false, continuesRight: false,
            sp: sp,
        )
        #expect(points.first == CGPoint(x: 50, y: 40 + 2.2 * sp))
        #expect(points.last == CGPoint(x: 150, y: 40 + 2.2 * sp))
    }

    @Test("the system and the skyline reserve a volta's hooks and label, below its line")
    func voltaVerticalExtent() throws {
        let sp = Self.metrics.sp
        let volta = try #require(try Self.voltas().first)
        let top = min(volta.from.y, volta.to.y)
        let origin = SpannerGeometry.voltaLabelOrigin(from: volta.from, to: volta.to, label: volta.label, sp: sp)
        let bottom = max(top + 2.2 * sp, origin.y + volta.label.size.height)
        let points = LayoutEngine.elementYPoints(volta.element, sp: sp)
        #expect(abs((points.max() ?? 0) - bottom) < 1e-9)
        let shape = try #require(LayoutElementShape.shape(
            for: volta.element, id: 0, xOffset: 0, metrics: Self.metrics,
        ))
        let rects = shape.rects.map(\.rect)
        #expect(abs((rects.map(\.maxY).max() ?? 0) - bottom) < 1e-9)
        #expect((rects.map(\.minY).min() ?? .infinity) <= top)
    }
}
