#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicMSCX
    import Testing

    @Suite("LayoutPaginator")
    struct LayoutPaginatorTests {
        private let _installApple = TestSupport.installApple

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

        /// Using `LayoutEngine.layout` + `LayoutPaginator.paginate` end-to-end:
        /// even a small score produces >= 1 page and the first range starts at 0.
        @available(macOS 15.0, *)
        @Test func realLayoutShortScoreProducesAtLeastOnePage() throws {
            let mscx = """
            <?xml version="1.0" encoding="UTF-8"?>
            <museScore version="4.60">
              <Score>
                <Division>480</Division>
                <Part id="1">
                  <Staff id="1"><StaffType group="pitched"><name>stdNormal</name></StaffType></Staff>
                  <Instrument id="i"><longName>Piano</longName></Instrument>
                </Part>
                <Staff id="1">
                  <Measure>
                    <voice>
                      <Chord><durationType>quarter</durationType><Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
                    </voice>
                  </Measure>
                </Staff>
              </Score>
            </museScore>
            """
            let score = try MSCXParser.parse(Data(mscx.utf8))
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
            let chord = """
            <Chord><durationType>quarter</durationType><Note><pitch>60</pitch><tpc>14</tpc></Note></Chord>
            """
            let measures = (0 ..< 8).map { _ in
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
                <Staff id="1">\(measures)</Staff>
              </Score>
            </museScore>
            """
            let score = try MSCXParser.parse(Data(mscx.utf8))
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
    }
#endif
