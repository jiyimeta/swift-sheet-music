#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    import PDFKit
    @testable import SheetMusic
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicPDF
    @testable import SheetMusicUI
    import Testing

    @MainActor struct PDFExporterPageLayoutTests {
        private let _installApple = TestSupport.installApple

        /// Default options should yield a MediaBox matching
        /// `pageLayout.{width,height} × 72`. testArpeggio.mscx declares
        /// A4-sized paper.
        @Test func mediaBoxMatchesScorePageSize() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let url = try #require(TestResources.url(
                forResource: "testArpeggio", withExtension: "mscx",
            ))
            let score = try MSCXParser.parse(
                Data(contentsOf: url),
            )
            let data = try PDFExporter.export(score: score)
            let doc = try #require(PDFDocument(data: data))
            let page = try #require(doc.page(at: 0))
            let bounds = page.bounds(for: .mediaBox)
            let expectedWidth = score.style.pageLayout.width * 72
            let expectedHeight = score.style.pageLayout.height * 72
            #expect(abs(bounds.width - expectedWidth) < 0.01)
            #expect(abs(bounds.height - expectedHeight) < 0.01)
        }

        /// `staffSize` denotes total staff height (= 4 × sp), so it
        /// resolves to `4 × spatium_mm × 72 / 25.4`. With a 1.76389mm
        /// spatium that's ~20.0 pt.
        @Test func staffSizeFollowsSpatium() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let url = try #require(TestResources.url(
                forResource: "testArpeggio", withExtension: "mscx",
            ))
            let score = try MSCXParser.parse(
                Data(contentsOf: url),
            )
            let resolved = PDFExporter.resolve(
                options: PDFExporter.Options(), score: score,
            )
            let expected = CGFloat(4 * score.style.spatium * 72.0 / 25.4)
            #expect(abs(resolved.staffSize - expected) < 1e-6)
        }

        /// Explicit override beats `.fromScore` resolution.
        @Test func explicitStaffSizeWins() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let score = Score(division: 480)
            let resolved = PDFExporter.resolve(
                options: PDFExporter.Options(
                    staffSize: .explicit(14),
                ),
                score: score,
            )
            #expect(resolved.staffSize == 14)
        }

        /// Page 1 (index 0) uses oddMargins; page 2 uses evenMargins
        /// when twosided, oddMargins otherwise.
        @Test func twosidedAlternatesMargins() {
            var layout = PageLayout.museScoreA4
            layout.oddLeftMargin = 0.5
            layout.evenLeftMargin = 1.0
            layout.twosided = true
            let page = EngravingPage.from(layout)
            #expect(
                page.margins(forPageIndex: 0).leading
                    == 0.5 * 72,
            )
            #expect(
                page.margins(forPageIndex: 1).leading
                    == 1.0 * 72,
            )
            #expect(
                page.margins(forPageIndex: 2).leading
                    == 0.5 * 72,
            )
        }

        @Test func singleSidedKeepsOddMargins() {
            var layout = PageLayout.museScoreA4
            layout.oddLeftMargin = 0.5
            layout.evenLeftMargin = 1.0
            layout.twosided = false
            let page = EngravingPage.from(layout)
            #expect(
                page.margins(forPageIndex: 0).leading
                    == 0.5 * 72,
            )
            #expect(
                page.margins(forPageIndex: 1).leading
                    == 0.5 * 72,
            )
        }

        /// `<LayoutBreak>page` on a measure forces the next system to
        /// start a new PDF page even when the current page would still
        /// have vertical room for it.
        @Test func paginatePageBreakClosesPage() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let pageGeom = EngravingPage(
                size: CGSize(width: 600, height: 1200),
                oddMargins: PageMargins(uniform: 30),
                evenMargins: PageMargins(uniform: 30),
                twosided: false,
            )
            /// Three short systems that together fit on one page.
            /// System 1's last measure carries pageBreak → forces close.
            func sys(
                originY: CGFloat,
                lastMeasurePageBreak: Bool,
            ) -> LayoutSystem {
                let m = LayoutMeasure(
                    measureIndex: 0, origin: .zero, width: 100,
                    elements: [], pageBreak: lastMeasurePageBreak,
                )
                return LayoutSystem(
                    origin: CGPoint(x: 0, y: originY),
                    size: CGSize(width: 100, height: 200),
                    measures: [m],
                    staffOrigins: [.zero],
                    staffAddresses: [],
                    staffGeometries: [],
                    partLabels: [],
                    spanners: [],
                    sp: 7.0,
                )
            }
            let s0 = sys(originY: 0, lastMeasurePageBreak: true)
            let s1 = sys(originY: 220, lastMeasurePageBreak: false)
            let s2 = sys(originY: 440, lastMeasurePageBreak: false)
            let pages = PDFExporter.paginate(
                systems: [s0, s1, s2], page: pageGeom,
            )
            // s0 closes its page (page 1) by the explicit pageBreak;
            // s1 + s2 share page 2.
            #expect(pages.count == 2)
            #expect(pages[0].systems.count == 1)
            #expect(pages[1].systems.count == 2)
        }

        /// Right margin derives per `Page::rm`:
        /// `width - printableWidth - leftMargin`.
        @Test func rightMarginDerivedFromPrintableWidth() {
            var layout = PageLayout.museScoreA4
            layout.width = 10
            layout.printableWidth = 8
            layout.oddLeftMargin = 1
            layout.evenLeftMargin = 1.5
            #expect(layout.oddRightMargin == 1)
            #expect(layout.evenRightMargin == 0.5)
        }

        // MARK: - Frames

        /// A page `height` tall with 30 pt margins all round: `height - 60` of room.
        private func page(height: CGFloat) -> EngravingPage {
            EngravingPage(
                size: CGSize(width: 600, height: height),
                oddMargins: PageMargins(uniform: 30),
                evenMargins: PageMargins(uniform: 30),
                twosided: false,
            )
        }

        /// A 200 pt tall system at `originY`, its measure carrying a page break when `pageBreak`.
        private func system(originY: CGFloat, pageBreak: Bool = false) -> LayoutSystem {
            LayoutSystem(
                origin: CGPoint(x: 0, y: originY), size: CGSize(width: 100, height: 200),
                measures: [
                    LayoutMeasure(measureIndex: 0, origin: .zero, width: 100, elements: [], pageBreak: pageBreak),
                ],
                staffOrigins: [.zero], staffAddresses: [], staffGeometries: [], partLabels: [], spanners: [], sp: 7,
            )
        }

        /// A box `height` points tall at `originY`, a page break after it when `pageBreakAfter`.
        private func frame(originY: CGFloat, height: CGFloat, pageBreakAfter: Bool = false) -> LayoutFrame {
            LayoutFrame(
                kind: .vertical, beforeMeasureIndex: 0, originY: originY, height: height,
                content: LayoutTitleFrame(height: height, texts: []), images: [], pageBreakAfter: pageBreakAfter,
            )
        }

        /// Systems at `origins` and one box over `box` with a page break after it.
        private func breakingDocument(origins: [CGFloat], box: Range<CGFloat>) -> LayoutDocument {
            LayoutDocument(
                size: CGSize(width: 600, height: (origins.last ?? 0) + 200),
                systems: origins.map { system(originY: $0) }, metrics: StaffMetrics(staffSize: 28),
                frames: [frame(originY: box.lowerBound, height: box.upperBound - box.lowerBound, pageBreakAfter: true)],
            )
        }

        /// A box with a page break stays on the sheet it closes (MuseScore `pagelayout.cpp:246`): the batch after it
        /// starts at the box's bottom, not at the system above it, and the host's sheets put the box on the sheet
        /// above. S0 [0, 200], the box [210, 290], S1 [300, 500], S2 [520, 720] on 1140 pt of room.
        @Test func theBatchAfterABoxBreakStartsAtTheBoxsBottom() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let document = breakingDocument(origins: [0, 300, 520], box: 210 ..< 290)
            let batches = PDFExporter.paginate(document: document, page: page(height: 1200), policy: .honor)
            #expect(batches.map(\.systems.count) == [1, 2])
            #expect(batches.map(\.startY) == [0, 290])
            let size = CGSize(width: 600, height: 1200)
            let sheets = batches.map { batch in
                PDFExporter.Sheet(
                    systems: batch.systems, pageStartY: batch.startY, pageSize: size, margins: PageMargins(uniform: 30),
                )
            }
            #expect(PDFExporter.frames(of: sheets, in: document).map { $0.map(\.originY) } == [[210], []])
        }

        /// The sheet above must hold the box too: when the box does not fit under S1, S1 moves to the next sheet with
        /// it. S0 [0, 200], S1 [220, 420], the box [430, 690], S2 [700, 900] on 540 pt of room.
        @Test func aBoxBreakThatDoesNotFitTakesTheSystemAboveItAlong() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let document = breakingDocument(origins: [0, 220, 700], box: 430 ..< 690)
            let batches = PDFExporter.paginate(document: document, page: page(height: 600), policy: .honor)
            #expect(batches.map(\.systems.count) == [1, 1, 1])
            #expect(batches.map(\.startY) == [0, 220, 690])
        }

        /// A frame's page break starts a page at the system below it with room to spare, and that page starts at the
        /// previous system's bottom so the frame is on it. `.ignoreAll` ignores the break, as it does a measure's.
        @Test func forcedBreakStartsAPageAtThePreviousSystemsBottom() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let systems = [system(originY: 0), system(originY: 300), system(originY: 520)]
            let pages = PDFExporter.paginate(
                systems: systems, page: page(height: 1200), forcedBreaksBefore: [1], systemsWithFrameAbove: [1],
            )
            #expect(pages.map(\.systems.count) == [1, 2])
            #expect(pages.map(\.startY) == [0, 200])
            let ignored = PDFExporter.paginate(
                systems: systems, page: page(height: 1200), policy: .ignoreAll,
                forcedBreaksBefore: [1], systemsWithFrameAbove: [1],
            )
            #expect(ignored.map(\.systems.count) == [3])
        }

        /// A frame between the last system of one page and the first of the next is on the later page: that page
        /// starts at the previous system's bottom, not at its first system's top. Without a frame there the start is
        /// unchanged.
        @Test func frameBetweenPagesLandsOnTheLaterPage() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            // On 400 pt of room the second system does not fit under the first; a frame sits between them.
            let systems = [system(originY: 0), system(originY: 300)]
            let framed = PDFExporter.paginate(systems: systems, page: page(height: 460), systemsWithFrameAbove: [1])
            let bare = PDFExporter.paginate(systems: systems, page: page(height: 460))
            #expect(framed.map(\.startY) == [0, 200])
            #expect(bare.map(\.startY) == [0, 300])
        }

        /// The sheets a host builds follow the same rule: the frame above a sheet's first system is that sheet's even
        /// when the sheet starts at the system's top, and the last sheet takes the frames after the last system.
        @Test func sheetFramesFollowThePageRule() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let systems = [system(originY: 0), system(originY: 300)]
            let document = LayoutDocument(
                size: CGSize(width: 600, height: 550), systems: systems, metrics: StaffMetrics(staffSize: 28),
                frames: [frame(originY: 210, height: 80), frame(originY: 510, height: 40)],
            )
            let size = CGSize(width: 600, height: 460)
            let margins = PageMargins(uniform: 30)
            let sheets = [
                PDFExporter.Sheet(systems: [systems[0]], pageStartY: 0, pageSize: size, margins: margins),
                PDFExporter.Sheet(systems: [systems[1]], pageStartY: 300, pageSize: size, margins: margins),
            ]
            let tops = PDFExporter.frames(of: sheets, in: document).map { $0.map(\.originY) }
            #expect(tops == [[], [210, 510]])
        }

        /// Frames after the last system that do not fit under it get a batch with no systems, starting at the last
        /// system's bottom; frames that fit get none.
        @Test func trailingFrameThatDoesNotFitMakesAFramesOnlyBatch() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let systems = [system(originY: 0), system(originY: 220)]
            let spilled = PDFExporter.paginate(systems: systems, page: page(height: 1200), trailingFramesBottom: 1200)
            let fitting = PDFExporter.paginate(systems: systems, page: page(height: 1200), trailingFramesBottom: 1100)
            #expect(spilled.map(\.systems.count) == [2, 0])
            #expect(spilled.last?.startY == 420)
            #expect(fitting.map(\.systems.count) == [2])
        }

        /// A page break on the last system's last measure sends the frames after it to a batch of their own even when
        /// they would fit under it (MuseScore `pagelayout.cpp:246`); `.ignoreAll` drops the break, so they stay.
        @Test func trailingFramesAfterAPageBreakGetTheirOwnBatch() {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let systems = [system(originY: 0), system(originY: 220, pageBreak: true)]
            let honored = PDFExporter.paginate(systems: systems, page: page(height: 1200), trailingFramesBottom: 500)
            let ignored = PDFExporter.paginate(
                systems: systems, page: page(height: 1200), policy: .ignoreAll, trailingFramesBottom: 500,
            )
            #expect(honored.map(\.systems.count) == [2, 0])
            #expect(honored.last?.startY == 420)
            #expect(ignored.map(\.systems.count) == [2])
        }

        /// `export(score:)` of frames-boxes draws a PDF page per batch, and VBox B's page break starts the batch that
        /// holds the system below it.
        @Test func exportOfFramesBoxesDrawsAPagePerBatch() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let score = try MSCXParser.parse(MSCXFixtureLoader.mscxData("frames-boxes"))
            let paged = PDFExporter.pagedLayout(score: score, options: PDFExporter.Options())
            let breakMatch = paged.document.frames.first { $0.pageBreakAfter }
            let breaking = try #require(breakMatch)
            let belowMatch = paged.document.systems.first { $0.origin.y >= breaking.bottom }
            let below = try #require(belowMatch)
            let starts = paged.batches.compactMap { $0.systems.first?.origin.y }
            #expect(starts.contains(below.origin.y))
            let data = try PDFExporter.export(score: score)
            let pdf = try #require(PDFDocument(data: data))
            #expect(pdf.pageCount == paged.batches.count)
        }
    }
#endif
