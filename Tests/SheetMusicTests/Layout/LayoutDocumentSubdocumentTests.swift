#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    /// On Android and WebAssembly, Foundation's CoreGraphics shims also export `CGFloat`,
    /// `CGPoint`, `CGSize` (see `Sources/SheetMusicLayout/Fonts/CGTypes+Android.swift`), so
    /// anchor explicitly to SheetMusicLayout's own definitions instead of leaving it ambiguous.
    ///
    /// `private typealias` keeps these file-scoped — a module-scope `typealias CGFloat` here
    /// would collide with the same pattern in every other file in this target that needs it.
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
    private typealias CGSize = SheetMusicLayout.CGSize
#endif

@Suite("LayoutDocument.subdocument")
struct LayoutDocumentSubdocumentTests {
    // MARK: - Helpers

    /// Constructs a lightweight `LayoutSystem` stub whose bottom edge in
    /// document coordinates is `originY + height`.
    private func makeSystem(originY: CGFloat, height: CGFloat) -> LayoutSystem {
        LayoutSystem(
            origin: CGPoint(x: 0, y: originY),
            size: CGSize(width: 100, height: height),
            measures: [],
            staffOrigins: [],
            staffAddresses: [],
            staffGeometries: [],
            partLabels: [],
            spanners: [],
            sp: 7,
        )
    }

    private func makeDocument() -> LayoutDocument {
        LayoutDocument(
            size: CGSize(width: 100, height: 320),
            systems: [
                makeSystem(originY: 0, height: 100),
                makeSystem(originY: 120, height: 100),
                makeSystem(originY: 240, height: 100),
            ],
            metrics: StaffMetrics(staffSize: 28),
        )
    }

    // MARK: - Slice count + origin shift

    /// Slicing a middle page lifts its first system's origin.y to ~0 and
    /// returns exactly the systems in the range.
    @Test func sliceCountAndOriginShift() {
        let doc = makeDocument()
        // Page starting at system 1 (doc-Y 120). Lift by -120.
        let sub = doc.subdocument(systems: 1 ..< 3, yOffset: -120)

        #expect(sub.systems.count == 2)
        #expect(abs(sub.systems[0].origin.y - 0) < 0.0001)
        // Second system was at 240; shifted by -120 → 120.
        #expect(abs(sub.systems[1].origin.y - 120) < 0.0001)
        // Content bound is the last system's shifted bottom: 120 + 100 = 220.
        #expect(abs(sub.size.height - 220) < 0.0001)
        // Width is carried unchanged; title frame is dropped.
        #expect(sub.size.width == doc.size.width)
        #expect(sub.titleFrame == nil)
    }

    /// The first page (yOffset 0) keeps document-absolute origins.
    @Test func firstPageKeepsOrigins() {
        let doc = makeDocument()
        let sub = doc.subdocument(systems: 0 ..< 1, yOffset: 0)

        #expect(sub.systems.count == 1)
        #expect(abs(sub.systems[0].origin.y - 0) < 0.0001)
        #expect(abs(sub.size.height - 100) < 0.0001)
    }

    // MARK: - Frames

    /// A box `height` points tall at `originY`, a page break after it when `pageBreakAfter`.
    private func makeFrame(originY: CGFloat, height: CGFloat, pageBreakAfter: Bool = false) -> LayoutFrame {
        LayoutFrame(
            kind: .vertical, beforeMeasureIndex: 0, originY: originY, height: height,
            content: LayoutTitleFrame(height: height, texts: []), images: [], pageBreakAfter: pageBreakAfter,
        )
    }

    /// S0 [0, 100] · F1 [110, 150] · S1 [160, 260] · F2 [270, 300] · S2 [310, 410] · F3 [420, 460].
    private func makeFramedDocument() -> LayoutDocument {
        LayoutDocument(
            size: CGSize(width: 100, height: 460),
            systems: [
                makeSystem(originY: 0, height: 100),
                makeSystem(originY: 160, height: 100),
                makeSystem(originY: 310, height: 100),
            ],
            metrics: StaffMetrics(staffSize: 28),
            frames: [
                makeFrame(originY: 110, height: 40),
                makeFrame(originY: 270, height: 30),
                makeFrame(originY: 420, height: 40),
            ],
        )
    }

    /// A page holds the frame between the previous page's last system and its own first, lifted with its systems;
    /// the page above holds none of it.
    @Test func frameInsideThePageIsCarriedAndShifted() {
        let document = makeFramedDocument()
        let above = document.subdocument(systems: 0 ..< 1, yOffset: 0, isLastPage: false)
        let page = document.subdocument(systems: 1 ..< 2, yOffset: -100, isLastPage: false)
        #expect(above.frames.isEmpty)
        #expect(page.frames.map(\.originY) == [10])
        #expect(page.frames.map(\.height) == [40])
        #expect(abs(page.size.height - 160) < 0.0001)
        #expect(page.titleImages.isEmpty)
    }

    /// The last range (the two-argument form: it ends at the last system) takes every frame below its top, the ones
    /// after its last system too, and is as tall as the lowest of them.
    @Test func lastRangeTakesEveryFrameBelowItsTop() {
        let page = makeFramedDocument().subdocument(systems: 2 ..< 3, yOffset: -260)
        #expect(page.frames.map(\.originY) == [10, 160])
        #expect(abs(page.size.height - 200) < 0.0001)
    }

    /// Before a frames-only page the range keeps only the frames above its last system's bottom; the empty range takes
    /// the rest and is as tall as they are.
    @Test func framesOnlyPageTakesTheTrailingFrame() {
        let document = makeFramedDocument()
        let before = document.subdocument(systems: 2 ..< 3, yOffset: -260, isLastPage: false)
        let framesOnly = document.subdocument(systems: 3 ..< 3, yOffset: -410, isLastPage: true)
        #expect(before.frames.map(\.originY) == [10])
        #expect(abs(before.size.height - 150) < 0.0001)
        #expect(framesOnly.systems.isEmpty)
        #expect(framesOnly.frames.map(\.originY) == [10])
        #expect(abs(framesOnly.size.height - 50) < 0.0001)
    }
}

extension LayoutDocumentSubdocumentTests {
    // MARK: - A box's page break (MuseScore `pagelayout.cpp:246`)

    /// S0 [0, 100] · B1 [110, 150] (break) · P1 [160, 180] · S1 [200, 300] · B2 [310, 330] (break) · B3 [340, 370]
    /// (break) · S2 [380, 480] · P2 [490, 510] · S3 [520, 620] · B4 [630, 650] (break, after the last system).
    private func makeBreakingDocument() -> LayoutDocument {
        let boxes: [(CGFloat, CGFloat, Bool)] = [
            (110, 40, true), (160, 20, false), (310, 20, true), (340, 30, true), (490, 20, false), (630, 20, true),
        ]
        return LayoutDocument(
            size: CGSize(width: 100, height: 650),
            systems: [0, 200, 380, 520].map { makeSystem(originY: $0, height: 100) },
            metrics: StaffMetrics(staffSize: 28),
            frames: boxes.map { makeFrame(originY: $0.0, height: $0.1, pageBreakAfter: $0.2) },
        )
    }

    /// Without boxes a page starts at the bottom of the system before its first: the first page at 0, the systems-only
    /// rule every page consumer has always used.
    @Test func pageTopWithoutFramesIsThePreviousSystemsBottom() {
        let document = makeDocument()
        #expect(document.pageTop(ofPageStartingAt: 0) == 0)
        #expect(document.pageTop(ofPageStartingAt: 1) == 100)
        #expect(document.pageTop(ofPageStartingAt: 2) == 220)
        #expect(document.pageTop(ofPageStartingAt: 3) == 340)
    }

    /// A box with a page break stays on the page it closes, so the next page starts at its bottom: the lowest of two
    /// such boxes, never a plain box's bottom, and — for a frames-only last page — the last system's, since no system
    /// follows the boxes after it.
    @Test func pageTopIsTheBreakingBoxsBottom() {
        let document = makeBreakingDocument()
        #expect(document.pageTop(ofPageStartingAt: 0) == 0)
        #expect(document.pageTop(ofPageStartingAt: 1) == 150) // B1, not P1 below it, nor S0's bottom (100)
        #expect(document.pageTop(ofPageStartingAt: 2) == 370) // the lower of B2 and B3
        #expect(document.pageTop(ofPageStartingAt: 3) == 480) // P2 has no break: S2's bottom
        #expect(document.pageTop(ofPageStartingAt: 4) == 620) // B4 follows the last system: no system below it
    }

    /// Each page holds the boxes whose top lies in `[pageTop(first), pageTop(next page's first))`: a box with a break
    /// on the page above it, a plain box below it on the next. Both breaking boxes between S1 and S2 stay on S1's page.
    @Test func aBreakingBoxIsOnThePageItCloses() {
        let document = makeBreakingDocument()
        let first = document.subdocument(systems: 0 ..< 1, yOffset: 0, isLastPage: false)
        let middle = document.subdocument(systems: 1 ..< 2, yOffset: -150, isLastPage: false)
        let last = document.subdocument(systems: 2 ..< 4, yOffset: -370, isLastPage: true)
        #expect(first.frames.map(\.originY) == [110])
        #expect(abs(first.size.height - 150) < 0.0001)
        #expect(middle.frames.map(\.originY) == [10, 160, 190])
        #expect(abs(middle.size.height - 220) < 0.0001)
        #expect(last.frames.map(\.originY) == [120, 260])
    }

    /// Across pages cut at the systems after each breaking box, every box is on exactly one page, unmoved.
    @Test func everyBoxIsOnOnePageAcrossABreak() {
        let document = makeBreakingDocument()
        let ranges = [0 ..< 1, 1 ..< 2, 2 ..< 4]
        let carried = ranges.enumerated().flatMap { index, range in
            let top = document.pageTop(ofPageStartingAt: range.lowerBound)
            let page = document.subdocument(systems: range, yOffset: -top, isLastPage: index == ranges.count - 1)
            return page.frames.map { frame in
                var moved = frame
                moved.originY += top
                return moved
            }
        }
        #expect(carried == document.frames)
    }
}
