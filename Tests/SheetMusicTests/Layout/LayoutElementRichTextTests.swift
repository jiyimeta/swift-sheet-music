#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

/// The passes that rebuild a text element — the per-staff translate, the horizontal clamp, the lyric-row shift —
/// carry its runs along: a pass that dropped them would draw the text plain wherever it moved it (Review Focus 5).
@Suite("LayoutElement rich text payload")
struct LayoutElementRichTextTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    private static func rich() -> LayoutRichText {
        LayoutRichText(
            RichText(lines: [[.text("Solo", RichTextFormat(bold: true))]]),
            style: .staffText, metrics: StaffMetrics(staffSize: 20),
        )
    }

    private static func payload(_ element: LayoutElement) -> LayoutRichText? {
        switch element {
        case let .staffText(_, _, _, _, _, _, _, _, richText),
             let .rehearsalMark(_, _, _, _, _, _, _, richText),
             let .marker(_, _, _, _, richText),
             let .jump(_, _, _, richText),
             let .textMark(_, _, _, richText):
            richText
        default:
            nil
        }
    }

    private static func elements() -> [LayoutElement] {
        let rich = rich()
        let origin = CGPoint(x: 10, y: 20)
        return [
            .staffText(text: "Solo", origin: origin, color: nil, style: .staffText, anchor: nil, richText: rich),
            .rehearsalMark(
                text: "Solo", origin: origin, frame: .rectangle, color: nil, measureIndex: 0, richText: rich,
            ),
            .marker(kind: .other, text: "Solo", origin: origin, richText: rich),
            .jump(text: "Solo", origin: origin, richText: rich),
            .textMark(kind: .lyrics(), text: "Solo", origin: origin, richText: rich),
        ]
    }

    @Test("the vertical translate keeps every text element's runs")
    func translateKeepsRuns() {
        for element in Self.elements() {
            #expect(Self.payload(LayoutEngine.translate(element: element, dy: 12)) == Self.rich())
        }
    }

    @Test("the horizontal clamp keeps the runs of the texts it moves")
    func clampKeepsRuns() {
        for element in Self.elements() {
            #expect(Self.payload(LayoutEngine.translateX(element: element, dx: -4)) == Self.rich())
        }
    }

    @Test("the lyric-row shift keeps a syllable's runs")
    func lyricShiftKeepsRuns() throws {
        let lyric = try #require(Self.elements().last)
        #expect(Self.payload(LayoutEngine.shiftLyricTextY(lyric, dy: 3)) == Self.rich())
    }
}
