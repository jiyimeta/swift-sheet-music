import Foundation
@testable import SheetMusicCore
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

@Suite("LayoutPaginator")
struct LayoutPaginatorTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    // MARK: - Helpers

    /// Constructs a lightweight `LayoutSystem` stub whose bottom edge in
    /// document coordinates is `originY + height`. `pageBreak` controls
    /// whether the last measure carries an authored page break.
    private func makeSystem(
        originY: CGFloat,
        height: CGFloat,
        pageBreak: Bool = false,
    ) -> LayoutSystem {
        let measure = LayoutMeasure(
            measureIndex: 0,
            origin: .zero,
            width: 100,
            elements: [],
            pageBreak: pageBreak,
        )
        return LayoutSystem(
            origin: CGPoint(x: 0, y: originY),
            size: CGSize(width: 100, height: height),
            measures: [measure],
            staffOrigins: [],
            staffAddresses: [],
            staffGeometries: [],
            partLabels: [],
            spanners: [],
            sp: 7,
        )
    }

    // MARK: - Basic invariants

    /// An empty systems array returns an empty page list.
    @Test func emptySystemsReturnsEmpty() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let result = LayoutPaginator.paginate(
            systems: [],
            pageHeight: 800,
            policy: .honor,
        )
        #expect(result.isEmpty)
    }

    /// A zero (or negative) page height returns an empty page list.
    @Test func zeroPageHeightReturnsEmpty() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let systems = [makeSystem(originY: 0, height: 100)]
        #expect(LayoutPaginator.paginate(
            systems: systems, pageHeight: 0, policy: .honor,
        ).isEmpty)
    }

    // MARK: - Short score: >= 1 page, first range starts at 0

    /// A short score (all systems fit on one page) produces exactly one page
    /// whose range starts at 0.
    @Test func shortScoreProducesOnePage() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        // Three systems, each 100 pt tall, spaced by a 20 pt gap in
        // document coordinates. Total span = 0..320. Page height 1000 fits
        // all of them.
        let systems = [
            makeSystem(originY: 0, height: 100),
            makeSystem(originY: 120, height: 100),
            makeSystem(originY: 240, height: 100),
        ]
        let pages = LayoutPaginator.paginate(
            systems: systems, pageHeight: 1000, policy: .ignoreAll,
        )
        #expect(pages.count >= 1)
        #expect(pages.first?.lowerBound == 0)
    }

    // MARK: - Contiguous coverage

    /// Ranges are contiguous and together cover [0, systems.count).
    /// Exercises the normal vertical-overflow path with a small page height.
    @Test func rangesAreContiguousAndCoverAll() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        // Six systems, each 100 pt tall with an 8 pt gap — document-Y
        // origins: 0, 108, 216, 324, 432, 540. Page height 250 fits at
        // most two systems (bottom of system 1 is at 208; adding system 2
        // brings the bottom to 316 which is > 250, so a new page opens).
        var systems: [LayoutSystem] = []
        for i in 0 ..< 6 {
            systems.append(makeSystem(
                originY: CGFloat(i) * 108,
                height: 100,
            ))
        }
        let pages = LayoutPaginator.paginate(
            systems: systems,
            pageHeight: 250,
            policy: .ignoreAll,
        )

        // Must have more than one page.
        #expect(pages.count > 1)

        // Ranges must be contiguous.
        for i in 1 ..< pages.count {
            #expect(
                pages[i].lowerBound == pages[i - 1].upperBound,
                "range \(i) lower bound must equal range \(i - 1) upper bound",
            )
        }

        // First range starts at 0.
        #expect(pages.first?.lowerBound == 0)

        // Last range ends at systems.count.
        #expect(pages.last?.upperBound == systems.count)
    }

    // MARK: - Authored page-break behavior

    /// Under `.honor`, an authored `<LayoutBreak>page` closes the page
    /// immediately even when vertical space remains.
    @Test func honorClosesPageOnPageBreak() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        // Three 100 pt systems, page height 1000 (plenty of room).
        // System at index 1 carries a pageBreak flag.
        let systems = [
            makeSystem(originY: 0, height: 100, pageBreak: false),
            makeSystem(originY: 100, height: 100, pageBreak: true),
            makeSystem(originY: 200, height: 100, pageBreak: false),
        ]
        let pages = LayoutPaginator.paginate(
            systems: systems, pageHeight: 1000, policy: .honor,
        )
        #expect(pages.count == 2, "page break on system 1 should split into 2 pages")
        #expect(pages[0] == 0 ..< 2)
        #expect(pages[1] == 2 ..< 3)
    }

    /// Under `.ignoreAll`, an authored page break is ignored; only vertical
    /// overflow creates a new page.
    @Test func ignoreAllIgnoresPageBreak() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let systems = [
            makeSystem(originY: 0, height: 100, pageBreak: false),
            makeSystem(originY: 100, height: 100, pageBreak: true),
            makeSystem(originY: 200, height: 100, pageBreak: false),
        ]
        let pages = LayoutPaginator.paginate(
            systems: systems, pageHeight: 1000, policy: .ignoreAll,
        )
        #expect(pages.count == 1, ".ignoreAll should pack all systems on one page")
        #expect(pages[0] == 0 ..< 3)
    }

    // MARK: - Real layout integration

    /// `measures` measures of four quarter notes on one piano staff; at a narrow width several make several systems.
    private func quarterNoteScore(measures: Int) throws -> Score {
        let chord = """
        <Chord><durationType>quarter</durationType><Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
        """
        let bars = (0 ..< measures).map { _ in
            "<Measure><voice>\(chord)\(chord)\(chord)\(chord)</voice></Measure>"
        }.joined()
        let mscx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <museScore version="4.60">
          <Score>
            <Division>480</Division>
            <Part id="1">
              <Staff id="1"><StaffType group="pitched"><name>stdNormal</name></StaffType></Staff>
              <Instrument id="i"><longName>Piano</longName></Instrument>
            </Part>
            <Staff id="1">\(bars)</Staff>
          </Score>
        </museScore>
        """
        return try MSCXParser.parse(Data(mscx.utf8))
    }

    /// Using `LayoutEngine.layout` + `LayoutPaginator.paginate` end-to-end:
    /// even a small score produces >= 1 page and the first range starts at 0.
    @available(macOS 15.0, *)
    @Test func realLayoutShortScoreProducesAtLeastOnePage() throws {
        let score = try quarterNoteScore(measures: 1)
        let doc = LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(staffSize: 20, wrapToViewWidth: true),
            availableWidth: 400,
        )
        let pages = LayoutPaginator.paginate(
            systems: doc.systems,
            pageHeight: 800,
            policy: .honor,
        )
        #expect(pages.count >= 1)
        #expect(pages.first?.lowerBound == 0)
    }

    /// A multi-system score paginated with a small `pageHeight` produces
    /// contiguous, non-overlapping ranges that together span all systems.
    @available(macOS 15.0, *)
    @Test func realLayoutMultiPageContiguousCoverage() throws {
        // Eight measures so the engine emits multiple systems at a narrow width.
        let score = try quarterNoteScore(measures: 8)
        let doc = LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(staffSize: 20, wrapToViewWidth: true),
            availableWidth: 200,
        )
        // Use a small page height to force multiple pages.
        let pageHeight: CGFloat = 60
        let pages = LayoutPaginator.paginate(
            systems: doc.systems,
            pageHeight: pageHeight,
            policy: .ignoreAll,
        )

        #expect(pages.count >= 1)
        #expect(pages.first?.lowerBound == 0)
        #expect(pages.last?.upperBound == doc.systems.count)

        for i in 1 ..< pages.count {
            #expect(
                pages[i].lowerBound == pages[i - 1].upperBound,
                "ranges must be contiguous at boundary \(i)",
            )
        }
    }

    @Test("a forced break starts a page with room to spare; trailing frames past the page get an empty range")
    func framePaginationInputs() {
        let origins: [CGFloat] = [0, 120, 240]
        let systems = origins.map { makeSystem(originY: $0, height: 100) }
        let broken = origins.map { makeSystem(originY: $0, height: 100, pageBreak: $0 == 240) }
        func cut(
            _ policy: LayoutBreakPolicy, forced: [Int: CGFloat] = [:], trailing: CGFloat? = nil,
            list: [LayoutSystem]? = nil,
        ) -> [Range<Int>] {
            LayoutPaginator.paginate(
                systems: list ?? systems, pageHeight: 1000, policy: policy,
                pageBreaksBefore: forced, trailingFramesBottom: trailing,
            )
        }
        #expect(cut(.honor, forced: [2: 230]) == [0 ..< 2, 2 ..< 3])
        #expect(cut(.ignoreAll, forced: [2: 230]) == [0 ..< 3])
        #expect(cut(.honor, forced: [0: 0, 3: 400]) == [0 ..< 3]) // a break before system 0 or past the last: no page
        #expect(cut(.honor, trailing: 1100) == [0 ..< 3, 3 ..< 3])
        #expect(cut(.honor, trailing: 1000) == [0 ..< 3])
        // After a page break on the last system trailing frames get a page even when they fit; `.ignoreAll` drops it.
        #expect(cut(.honor, trailing: 400, list: broken) == [0 ..< 3, 3 ..< 3])
        #expect(cut(.ignoreAll, trailing: 400, list: broken) == [0 ..< 3])
    }

    /// `frames-boxes.mscx` wrapped at 700 pt: S0, VBox B (a page break after it), S1, the TBox, S2, VBox C.
    private func framesDocument() throws -> LayoutDocument {
        let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("frames-boxes"))
        return LayoutEngine.layout(score: score, options: ScoreViewOptions(), availableWidth: 700)
    }

    private func bottom(_ system: LayoutSystem) -> CGFloat {
        system.origin.y + system.size.height
    }

    private func systemIndex(below frame: LayoutFrame, in document: LayoutDocument) throws -> Int {
        try #require(document.systems.firstIndex { $0.origin.y >= frame.bottom })
    }

    /// Each range's page (`LayoutBridge.pageDocument`) and the top it was lifted by; the last takes trailing frames.
    private func pages(_ ranges: [Range<Int>], of document: LayoutDocument) -> [(top: CGFloat, page: LayoutDocument)] {
        ranges.enumerated().map { index, range in
            let top = document.pageTop(ofPageStartingAt: range.lowerBound)
            let page = document.subdocument(systems: range, yOffset: -top, isLastPage: index == ranges.count - 1)
            return (top: top, page: page)
        }
    }

    @Test("a frame below a page's last system is on the next page and on no other")
    func frameLandsOnTheNextPageWhenTheBreakFallsBeforeIt() throws {
        let document = try framesDocument()
        let tboxMatch = document.frames.first { $0.kind == .text }
        let breakMatch = document.frames.first { $0.pageBreakAfter }
        let tbox = try #require(tboxMatch)
        let breaking = try #require(breakMatch)
        let below = try systemIndex(below: tbox, in: document)
        let pageTop = try document.pageTop(ofPageStartingAt: systemIndex(below: breaking, in: document))
        // VBox B's break starts a page at `pageTop`, with room for the systems above the TBox, not the one below it.
        let ranges = document.paginate(pageHeight: bottom(document.systems[below]) - pageTop - 1, policy: .honor)
        let nextMatch = ranges.firstIndex { $0.lowerBound == below }
        let next = try #require(nextMatch)
        for (index, page) in pages(ranges, of: document).enumerated() {
            let carries = page.page.frames.contains { $0.kind == .text }
            #expect(carries == (index == next), "page \(index)")
        }
    }

    @Test("across the pages every frame appears once, in document order")
    func everyFrameIsOnExactlyOnePage() throws {
        let document = try framesDocument()
        let count = document.systems.count
        let lastSystemHeight = bottom(document.systems[count - 1]) - bottom(document.systems[count - 2])
        // A cut with room under the last system for VBox C, and one without, which gives C a frames-only page.
        for (pageHeight, framesOnly) in [(document.size.height / 2, false), (lastSystemHeight + 1, true)] {
            let ranges = document.paginate(pageHeight: pageHeight, policy: .honor)
            #expect((ranges.last == count ..< count) == framesOnly, "page height \(pageHeight)")
            let carried = pages(ranges, of: document).flatMap { top, page in
                page.frames.map { frame in
                    var moved = frame
                    moved.originY += top
                    return moved
                }
            }
            #expect(carried.map(\.kind) == document.frames.map(\.kind), "page height \(pageHeight)")
            let misplaced = zip(carried, document.frames).filter { abs($0.originY - $1.originY) > 0.001 }
            #expect(misplaced.isEmpty, "page height \(pageHeight)")
        }
    }

    @Test(
        "a frame's page break starts a page at the system below it even when that system fits",
        arguments: [.honor, .ignoreSystemBreaks] as [LayoutBreakPolicy],
    )
    func pageBreakFrameForcesNewPage(policy: LayoutBreakPolicy) throws {
        let document = try framesDocument()
        let breakMatch = document.frames.first { $0.pageBreakAfter }
        let breaking = try #require(breakMatch)
        let below = try systemIndex(below: breaking, in: document)
        let ranges = document.paginate(pageHeight: document.size.height * 2, policy: policy)
        #expect(ranges == [0 ..< below, below ..< document.systems.count])
    }

    @Test("under .ignoreAll a frame's page break is ignored, as a measure's is")
    func ignoreAllIgnoresAFramePageBreak() throws {
        let document = try framesDocument()
        let ranges = document.paginate(pageHeight: document.size.height * 2, policy: .ignoreAll)
        #expect(ranges == [0 ..< document.systems.count])
    }

    @Test("a trailing frame that does not fit under the last system gets an empty last range of its own")
    func trailingFrameThatDoesNotFitMakesAFramesOnlyPage() throws {
        let document = try framesDocument()
        let count = document.systems.count
        let trailing = try #require(document.frames.last)
        let lastBottom = bottom(document.systems[count - 1])
        // The last system fits on a page of its own; VBox C, 7 sp below it, does not.
        let pageTop = bottom(document.systems[count - 2])
        let pageHeight = lastBottom - pageTop + 1
        try #require(trailing.bottom - pageTop > pageHeight)
        let ranges = document.paginate(pageHeight: pageHeight, policy: .honor)
        let last = try #require(ranges.last)
        #expect(last == count ..< count)
        let page = document.subdocument(systems: last, yOffset: -lastBottom, isLastPage: true)
        #expect(page.frames.map(\.kind) == [.vertical])
        #expect(page.size.height > 0)
    }

    @Test("without frames document.paginate is the systems-only cut: 8 bars, frames-boxes title-only, 29 bars")
    func noFramesIsTheOldPagination() throws {
        var stripped = try MSCXParser.parse(MSCXFixtureLoader.mscxData("frames-boxes"))
        stripped.blocks.removeAll { $0.beforeMeasureIndex > 0 }
        let repeats = try MSCXParser.parse(MSCXFixtureLoader.mscxData("testMeasureRepeats"))
        let options = ScoreViewOptions(staffSize: 20, wrapToViewWidth: true)
        let documents = try [
            LayoutEngine.layout(score: quarterNoteScore(measures: 8), options: options, availableWidth: 200),
            LayoutEngine.layout(score: stripped, options: options, availableWidth: 400),
            LayoutEngine.layout(score: repeats, options: options, availableWidth: 400),
        ]
        for document in documents {
            try #require(document.frames.isEmpty)
            try #require(document.systems.count > 1)
            let tallest = document.systems.map(\.size.height).max() ?? 0
            for policy in [.honor, .ignoreAll] as [LayoutBreakPolicy] {
                for height in [tallest + 1, document.size.height / 2] {
                    let old = LayoutPaginator.paginate(systems: document.systems, pageHeight: height, policy: policy)
                    #expect(document.paginate(pageHeight: height, policy: policy) == old)
                    #expect(old.count > 1)
                }
            }
        }
    }
}
