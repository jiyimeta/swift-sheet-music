import Foundation
@testable import SheetMusicBridgeCore
import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicMSCX
import Testing

#if !canImport(CoreGraphics)
    /// On Android and WebAssembly, Foundation's own CoreGraphics shims also export `CGFloat`,
    /// `CGPoint` and `CGSize` (see `Sources/SheetMusicLayout/Fonts/CGTypes+Android.swift`), so
    /// anchor explicitly to SheetMusicLayout's own definitions instead of leaving them ambiguous.
    ///
    /// `private typealias` keeps these file-scoped — a module-scope `typealias CGFloat` here
    /// would collide with the same pattern in every other file in this target that needs it.
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
    private typealias CGSize = SheetMusicLayout.CGSize
#endif

/// A box (`<VBox>` / `<TBox>`) with a page break after it stays at the bottom of the page it closes, and the next page
/// starts below it (MuseScore `pagelayout.cpp:246`): song 1's closing verses print on song 1's page, not above song
/// 2's title. `LayoutDocument.pageTop(ofPageStartingAt:)` is where that next page starts.
@Suite("A box's page break")
struct FramePageBreakTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    // MARK: - The cut

    /// The page after the box is measured from the box's bottom, not from the system above it. S0 [0, 100], S1
    /// [110, 210], the box [220, 300], then S2–S4 100 pt apart: on 400 pt the page from 300 holds S2–S4 (S4 ends 330
    /// below it), where one measured from S1's bottom (210) would end before S4 (420 below). The same whether the cut
    /// at S2 is the box's alone or S1's measure carries a page break too.
    @Test(arguments: [nil, 1] as [Int?])
    func theNextPageIsMeasuredFromTheBoxsBottom(measureBreakAt: Int?) {
        let document = Self.document(
            origins: [0, 110, 310, 420, 530], box: 220 ..< 300, measureBreakAt: measureBreakAt,
        )
        #expect(document.paginate(pageHeight: 400, policy: .honor) == [0 ..< 2, 2 ..< 5])
        #expect(document.pageTop(ofPageStartingAt: 2) == 300)
    }

    /// The page above must hold the box too. S0 [0, 100], S1 [110, 210], the box [220, 400], S2 [410, 510]: on 310 pt
    /// the box ends 400 below page 0's top, so S1 moves to the next page with it rather than leaving the box to open
    /// the page after (MuseScore would move only the box — a documented, rare deviation).
    @Test func aBoxThatDoesNotFitTakesTheSystemAboveItAlong() {
        let document = Self.document(origins: [0, 110, 410], box: 220 ..< 400)
        #expect(document.paginate(pageHeight: 310, policy: .honor) == [0 ..< 1, 1 ..< 2, 2 ..< 3])
        let held = document.subdocument(systems: 1 ..< 2, yOffset: 0, isLastPage: false).frames
        #expect(held.map(\.originY) == [220])
    }

    // MARK: - The policy is baked into the layout

    /// Laid out under `.ignoreAll` no box carries `pageBreakAfter`, so `pageTop` and `subdocument` — which take no
    /// policy — treat "Part II" as a plain box: the page whose first system follows it starts at the system above's
    /// bottom and holds it.
    @Test func ignoreAllLaysOutNoBoxPageBreak() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("frames-boxes"))
        let honoring = LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 700)
        // The control: honoring breaks, the box does carry its page break.
        #expect(honoring.frames.contains { $0.pageBreakAfter })
        let options = ScoreViewOptions(breakPolicy: .ignoreAll)
        let document = LayoutEngine.layout(score: score, options: options, availableWidth: 700)
        #expect(!document.frames.contains { $0.pageBreakAfter })
        let partII = try #require(Self.box(titled: "Part II", in: document))
        let below = try #require(document.systems.firstIndex { $0.origin.y >= partII.bottom })
        let previous = try #require(document.systems[..<below].last)
        let previousBottom = previous.origin.y + previous.size.height
        #expect(document.pageTop(ofPageStartingAt: below) == previousBottom)
        // A cut right above the box: page 0 ends with the system above it.
        let ranges = document.paginate(pageHeight: previousBottom + 1, policy: .ignoreAll)
        try #require(ranges.count > 1, "ranges \(ranges)")
        try #require(ranges[0] == 0 ..< below, "ranges \(ranges)")
        let above = document.subdocument(systems: ranges[0], yOffset: 0, isLastPage: false)
        let next = document.subdocument(systems: ranges[1], yOffset: 0, isLastPage: ranges.count == 2)
        #expect(!above.frames.contains(partII))
        #expect(next.frames.contains(partII))
    }

    // MARK: - End to end

    /// frames-boxes on an A4 page with its title, as MuseScore prints it: page 1 is the title, the first system and
    /// "Part II" — the box whose page break ends the page — and page 2 starts at that box's bottom with the next
    /// system. Read off the pages a host draws (`LayoutBridge`) and the placement it puts its own marks with.
    @Test func framesBoxesOnA4KeepsPartIIOnPageOne() throws {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("frames-boxes"))
        var wire = LayoutOptionsWire.verticalDefault
        wire.layoutMode = LayoutOptionsWire.Mode.page.rawValue
        let laidOut = LayoutBridge.computePages(score: score, pageWidthMM: 210, pageHeightMM: 297, options: wire)
        let document = laidOut.document
        try #require(document.titleFrame != nil)
        let partII = try #require(Self.box(titled: "Part II", in: document))
        let below = try #require(document.systems.firstIndex { $0.origin.y >= partII.bottom })
        let ranges = LayoutBridge.pageRanges(document: document, options: wire, pageHeightMM: 297, margins: .zero)
        // The control: the box's page break does cut an A4 page right below it.
        try #require(ranges.count > 1, "ranges \(ranges)")
        try #require(ranges[0] == 0 ..< below, "ranges \(ranges)")
        let first = LayoutBridge.pageDocument(0, of: ranges, in: document)
        let second = LayoutBridge.pageDocument(1, of: ranges, in: document)
        #expect(Self.box(titled: "Part II", in: first) == partII)
        #expect(Self.box(titled: "Part II", in: second) == nil)
        let placement = LayoutBridge.pagePlacement(document: document, options: wire, pageHeightMM: 297)
        #expect(Array(placement.pageTopsPt.prefix(2)) == [0, Double(partII.bottom)])
        try #require(laidOut.pages.count == ranges.count)
        #expect(Self.draws("Part II", in: laidOut.pages[0].commands))
        #expect(!Self.draws("Part II", in: laidOut.pages[1].commands))
    }

    // MARK: - Helpers

    /// 100 pt tall systems at `origins`, the one at `measureBreakAt` ending in a measure page break, and one box over
    /// `box` with a page break after it.
    private static func document(
        origins: [CGFloat], box: Range<CGFloat>, measureBreakAt: Int? = nil,
    ) -> LayoutDocument {
        let systems = origins.enumerated().map { index, originY in
            LayoutSystem(
                origin: CGPoint(x: 0, y: originY),
                size: CGSize(width: 100, height: 100),
                measures: [
                    LayoutMeasure(
                        measureIndex: index, origin: .zero, width: 100, elements: [],
                        pageBreak: index == measureBreakAt,
                    ),
                ],
                staffOrigins: [], staffAddresses: [], staffGeometries: [], partLabels: [], spanners: [], sp: 7,
            )
        }
        let height = box.upperBound - box.lowerBound
        let frame = LayoutFrame(
            kind: .vertical, beforeMeasureIndex: 0, originY: box.lowerBound, height: height,
            content: LayoutTitleFrame(height: height, texts: []), images: [], pageBreakAfter: true,
        )
        return LayoutDocument(
            size: CGSize(width: 100, height: (origins.last ?? 0) + 100),
            systems: systems,
            metrics: StaffMetrics(staffSize: 28),
            frames: [frame],
        )
    }

    /// The box in `document` that draws `text`.
    private static func box(titled text: String, in document: LayoutDocument) -> LayoutFrame? {
        document.frames.first { frame in frame.content.texts.contains { $0.text == text } }
    }

    /// Whether `commands` draw `string` as one `.text` command.
    private static func draws(_ string: String, in commands: [DrawCommand]) -> Bool {
        commands.contains { command in
            if case let .text(text, _, _, _, _) = command { text == string } else { false }
        }
    }
}
