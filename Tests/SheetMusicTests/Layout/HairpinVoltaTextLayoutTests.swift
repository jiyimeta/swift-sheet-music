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

    @Test("a volta's bracket geometry is unchanged: the label origin keeps the (sp, sp/2) offset")
    func voltaOrigin() {
        let sp = StaffMetrics(staffSize: 20).sp
        let from = CGPoint(x: 50, y: 40)
        let origin = SpannerGeometry.voltaLabelOrigin(from: from, to: CGPoint(x: 150, y: 40), sp: sp)
        #expect(origin == CGPoint(x: 50 + sp, y: 40 + sp / 2))
    }
}
