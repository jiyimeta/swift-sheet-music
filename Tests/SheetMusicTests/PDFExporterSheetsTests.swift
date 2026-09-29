#if os(macOS)
    import CoreGraphics
    import Foundation
    import SheetMusicCore
    import SheetMusicLayout
    import SheetMusicLayoutApple
    @testable import SheetMusicPDF
    import SwiftUI
    import Testing

    /// `export(score:options:)` as it stood in 3.6.2, before it was routed through `export(document:sheets:…)` — the
    /// oracle the routed version is held to. Verbatim apart from inlining the old private `makePDFInfo`; do not
    /// "improve" it.
    @available(macOS 15.0, *)
    @MainActor
    enum LegacyPDFExport {
        static func export(score: Score, options: PDFExporter.Options) throws -> Data {
            _ = SheetMusicLayoutApple.install
            let resolved = PDFExporter.resolve(options: options, score: score)
            let layoutOptions = ScoreViewOptions(
                staffSize: resolved.staffSize, systemGap: options.systemGap, wrapToViewWidth: true,
                breakPolicy: options.breakPolicy, showsInvisibleElements: false, spacing: options.spacing,
            )
            let availableWidth = max(
                resolved.staffSize * 4,
                resolved.page.size.width - resolved.page.oddMargins.leading - resolved.page.oddMargins.trailing,
            )
            let document = LayoutEngine.layout(score: score, options: layoutOptions, availableWidth: availableWidth)
            let pages = PDFExporter.paginate(
                systems: document.systems, page: resolved.page, policy: options.breakPolicy,
            )
            var info: [String: Any] = [kCGPDFContextCreator as String: "swift-sheet-music"]
            if let title = options.title { info[kCGPDFContextTitle as String] = title }
            if let author = options.author { info[kCGPDFContextAuthor as String] = author }
            let data = NSMutableData()
            guard let consumer = CGDataConsumer(data: data),
                  let pdfContext = CGContext(consumer: consumer, mediaBox: nil, info as CFDictionary)
            else { throw PDFExportError.contextCreationFailed }
            for (idx, page) in pages.enumerated() {
                let margins = resolved.page.margins(forPageIndex: idx)
                let view = PDFPageView(
                    systems: page.systems, pageStartY: page.startY,
                    titleFrame: idx == 0 ? document.titleFrame : nil, metrics: document.metrics,
                    pageSize: resolved.page.size, margins: margins, breakIndicatorVisibility: .none,
                    policy: options.breakPolicy,
                )
                let renderer = ImageRenderer(content: view)
                renderer.proposedSize = ProposedViewSize(
                    width: resolved.page.size.width, height: resolved.page.size.height,
                )
                renderer.scale = 1
                renderer.isOpaque = true
                renderer.render { _, drawInto in
                    var mediaBox = CGRect(origin: .zero, size: resolved.page.size)
                    pdfContext.beginPDFPage([
                        kCGPDFContextMediaBox as String: Data(bytes: &mediaBox, count: MemoryLayout<CGRect>.size),
                    ] as CFDictionary)
                    drawInto(pdfContext)
                    PageChromeRenderer.draw(
                        chrome: score.style.pageChrome, pageIndex: idx, pageCount: pages.count,
                        pageSize: resolved.page.size, margins: margins, metaTags: score.metaTags, into: pdfContext,
                    )
                    pdfContext.endPDFPage()
                }
            }
            pdfContext.closePDF()
            return data as Data
        }
    }

    @MainActor
    @Suite("PDFExporter — sheets the caller laid out")
    struct PDFExporterSheetsTests {
        private let _installApple = TestSupport.installApple

        /// `measures` whole-note bars on every one of `parts` single-staff parts.
        static func wholeNoteScore(measures: Int, parts: Int, titled: Bool = false) -> Score {
            let chord = Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)])
            let bars = (0 ..< measures).map { _ in Measure(voices: [Voice(elements: [.chord(chord)])]) }
            var style = ScoreStyle.museScoreDefaults
            if titled {
                // A page number in the header and the footer of EVERY page, first included, plus the page count.
                let row = TextRow(left: "", center: "$P / $N", right: "")
                for keyPath in [\PageChrome.header, \PageChrome.footer] {
                    style.pageChrome[keyPath: keyPath].enabled = true
                    style.pageChrome[keyPath: keyPath].showOnFirstPage = true
                    style.pageChrome[keyPath: keyPath].oddEvenDifferent = false
                    style.pageChrome[keyPath: keyPath].odd = row
                }
            }
            return Score(
                division: 480,
                parts: IdentifiedArray((0 ..< parts).map { index in
                    Part(id: "\(index + 1)", instrument: Instrument(id: "x"), staves: [Staff(measures: bars)])
                }),
                titleFrame: titled ? ScoreFrame(
                    heightSp: 12, texts: [FrameText(style: .title, text: "Sheet Title")],
                ) : nil,
                style: style,
            )
        }

        /// A fixture for the characterization test; `titled` adds a title frame and a page number to every page.
        struct Fixture: Sendable, CustomTestStringConvertible {
            let measures: Int
            let parts: Int
            let titled: Bool
            var testDescription: String {
                "\(measures) bars × \(parts) parts, titled: \(titled)"
            }
        }

        @Test(arguments: [
            Fixture(measures: 240, parts: 1, titled: false),
            Fixture(measures: 60, parts: 2, titled: false),
            Fixture(measures: 240, parts: 1, titled: true),
        ])
        func `routing export(score:) through the sheet entry point leaves every page unchanged`(
            fixture: Fixture,
        ) throws {
            guard #available(macOS 15.0, *) else { return }
            let score = Self.wholeNoteScore(measures: fixture.measures, parts: fixture.parts, titled: fixture.titled)
            let options = PDFExporter.Options(title: "T")
            let routed = try PDFPageRaster.pages(of: PDFExporter.export(score: score, options: options))
            let legacy = try PDFPageRaster.pages(of: LegacyPDFExport.export(score: score, options: options))
            #expect(routed.count > 1, "the fixture must paginate, or page 2's chrome and offset go untested")
            #expect(routed.count == legacy.count)
            for (index, (page, oracle)) in zip(routed, legacy).enumerated() {
                #expect(page.mediaBox == oracle.mediaBox)
                // Bound to a Bool first: a failed `==` on the byte arrays would print all of them.
                let identical = page.rgba == oracle.rgba
                #expect(identical, "page \(index + 1) differs from the 3.6.2 export")
            }
        }

        @Test
        func `each sheet is one page at its own size, drawn from its own start`() throws {
            guard #available(macOS 15.0, *) else { return }
            _ = SheetMusicLayoutApple.install
            let score = Self.wholeNoteScore(measures: 24, parts: 1)
            let document = LayoutEngine.layout(
                score: score, options: ScoreViewOptions(staffSize: 16), availableWidth: 500,
            )
            #expect(document.systems.count >= 2)
            let margins = PageMargins(top: 36, leading: 36, bottom: 36, trailing: 36)
            let sheets = [
                PDFExporter.Sheet(
                    systems: [document.systems[0]], pageStartY: 0,
                    pageSize: CGSize(width: 572, height: 400), margins: margins,
                ),
                PDFExporter.Sheet(
                    systems: [document.systems[1]],
                    pageStartY: document.systems[0].origin.y + document.systems[0].size.height,
                    pageSize: CGSize(width: 600, height: 420), margins: margins,
                ),
            ]
            let pages = try PDFPageRaster.pages(
                of: PDFExporter.export(document: document, sheets: sheets, score: score),
            )
            #expect(pages.count == 2)
            #expect(pages.map(\.mediaBox.size) == [CGSize(width: 572, height: 400), CGSize(width: 600, height: 420)])
            // Page 2 draws system 1 just below its top margin, not at its document Y.
            let system = document.systems[1]
            let top = 36 + system.origin.y + system.staffOrigins[0].y - sheets[1].pageStartY
            let band = CGRect(x: 36, y: top - 3, width: 400, height: 6)
            #expect(pages[1].markedPixels(in: band) > 0)
        }

        /// The title frame belongs to the first sheet alone, and each sheet gets its own header and footer.
        @Test
        func `the first sheet carries the title frame and every sheet its page chrome`() throws {
            guard #available(macOS 15.0, *) else { return }
            _ = SheetMusicLayoutApple.install
            let size = CGSize(width: 572, height: 400)
            let margins = PageMargins(top: 36, leading: 36, bottom: 36, trailing: 36)
            func render(titled: Bool) throws -> (PDFExporter.Sheet, [PDFPageRaster]) {
                let score = Self.wholeNoteScore(measures: 24, parts: 1, titled: titled)
                let document = LayoutEngine.layout(
                    score: score, options: ScoreViewOptions(staffSize: 16), availableWidth: 500,
                )
                #expect(document.systems.count >= 2)
                #expect((document.titleFrame != nil) == titled)
                let sheets = [
                    PDFExporter.Sheet(systems: [document.systems[0]], pageStartY: 0, pageSize: size, margins: margins),
                    PDFExporter.Sheet(
                        systems: [document.systems[1]], pageStartY: document.systems[1].origin.y,
                        pageSize: size, margins: margins,
                    ),
                ]
                let pdf = try PDFExporter.export(document: document, sheets: sheets, score: score)
                return try (sheets[0], PDFPageRaster.pages(of: pdf))
            }
            let (titledFirst, titled) = try render(titled: true)
            let (_, plain) = try render(titled: false)
            #expect(titled.count == 2)
            #expect(plain.count == 2)
            #expect(titledFirst.systems[0].origin.y > 0, "the title frame must push system 0 down")
            // The title draws on page 1 only: page 1 differs from the untitled one, and page 2's music — the rows
            // between the margins, since only the titled score carries a header and footer — is identical.
            let firstPageDiffers = titled[0].rgba != plain[0].rgba
            #expect(firstPageDiffers, "the title frame left page 1 unchanged")
            let content = CGFloat(36) ..< (size.height - 36)
            let secondPageMusicIdentical = titled[1].rows(content) == plain[1].rows(content)
            #expect(secondPageMusicIdentical, "page 2's music differs, so the title frame drew there too")
            let titleBand = CGRect(x: 36, y: 36, width: 500, height: titledFirst.systems[0].origin.y)
            #expect(titled[0].markedPixels(in: titleBand) > 0)
            // Header and footer sit in the margins of every page, and the page number differs between pages.
            for page in titled {
                #expect(page.markedPixels(in: CGRect(x: 0, y: 0, width: size.width, height: 36)) > 0)
                #expect(page.markedPixels(in: CGRect(x: 0, y: size.height - 36, width: size.width, height: 36)) > 0)
            }
            let headerRows = titled.map { $0.rows(0 ..< 36) }
            let pageNumbersDiffer = headerRows[0] != headerRows[1]
            #expect(pageNumbersDiffer, "pages 1 and 2 have the same header")
        }

        /// One bar under a hidden tempo marking — `Tempo(visible: false)`, which a layout that shows invisible
        /// elements parks in the measure's `invisibleElements` above the staff.
        static func scoreWithHiddenTempo() -> Score {
            let voice = Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)])),
            ])
            return Score(
                division: 480,
                parts: [Part(
                    id: "P1", instrument: Instrument(id: "voice"),
                    staves: [Staff(measures: [Measure(voices: [voice])])],
                )],
                systemMeasures: [SystemMeasure(elements: [
                    PositionedSystemElement(
                        position: .start, element: .tempo(Tempo(beatsPerSecond: 2, visible: false)),
                    ),
                ])],
            )
        }

        @Test
        func `invisible elements keep their room but print nothing when the switch is off`() throws {
            guard #available(macOS 15.0, *) else { return }
            _ = SheetMusicLayoutApple.install
            let score = Self.scoreWithHiddenTempo()
            let document = LayoutEngine.layout(
                score: score, options: ScoreViewOptions(showsInvisibleElements: true), availableWidth: 500,
            )
            let system = try #require(document.systems.first)
            #expect(!system.measures.flatMap(\.invisibleElements).isEmpty, "the fixture must park something")
            let sheet = PDFExporter.Sheet(
                systems: document.systems, pageStartY: 0, pageSize: CGSize(width: 572, height: 400),
                margins: PageMargins(top: 36, leading: 36, bottom: 36, trailing: 36),
            )
            let shown = try #require(PDFPageRaster.pages(of: PDFExporter.export(
                document: document, sheets: [sheet], score: score, options: .init(drawsInvisibleElements: true),
            )).first)
            let printed = try #require(PDFPageRaster.pages(of: PDFExporter.export(
                document: document, sheets: [sheet], score: score, options: .init(drawsInvisibleElements: false),
            )).first)
            let shownInk = shown.markedIndices
            let printedInk = printed.markedIndices
            #expect(printedInk.count < shownInk.count, "control: the switch has something to omit")
            // Nothing is added or moved — the layout is the same, only the parked marks go.
            let subset = printedInk.isSubset(of: shownInk)
            #expect(subset, "printing with the switch off added or moved ink")
            // And what went is the tempo text above the staff, not a note or a staff line.
            let staffTop = 36 + system.origin.y + system.staffOrigins[0].y
            let removedRows = shownInk.subtracting(printedInk).map { $0 / shown.width }
            #expect(try CGFloat(#require(removedRows.max())) / shown.scale < staffTop)
        }

        /// One bar with a quarter chord of a visible B4 and an invisible G4. The invisible note never leaves the
        /// chord — the layout keeps it in `measure.elements`, flagged `isInvisible` — so it is `drawSystem`'s per-note
        /// path, not the `invisibleElements` container, that decides whether its notehead prints. G4 sits inside the
        /// staff on purpose: a note that needs a ledger line has that line parked in `invisibleElements`, which the
        /// container guard would omit on its own and hide a broken per-note path.
        static func scoreWithHiddenNoteInChord() -> Score {
            let visible = Note(pitch: 71, tpc: 19)
            var hidden = Note(pitch: 67, tpc: 15)
            hidden.visible = false
            let voice = Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(Chord(duration: .quarter, notes: ChordNotes([visible, hidden]))),
            ])
            return Score(
                division: 480,
                parts: [Part(
                    id: "P1", instrument: Instrument(id: "voice"),
                    staves: [Staff(measures: [Measure(voices: [voice])])],
                )],
            )
        }

        @Test
        func `an invisible note inside a visible chord prints nothing when the switch is off`() throws {
            guard #available(macOS 15.0, *) else { return }
            _ = SheetMusicLayoutApple.install
            let score = Self.scoreWithHiddenNoteInChord()
            let document = LayoutEngine.layout(
                score: score, options: ScoreViewOptions(showsInvisibleElements: true), availableWidth: 500,
            )
            let system = try #require(document.systems.first)
            let measures = system.measures
            #expect(measures.flatMap(\.invisibleElements).isEmpty, "the chord must not be parked as a whole")
            let chordNotes = measures.flatMap(\.elements).compactMap { element -> [LayoutChordNote]? in
                if case let .chord(notes, _, _, _, _, _, _, _, _, _, _) = element { notes } else { nil }
            }.flatMap(\.self)
            #expect(chordNotes.count == 2, "both notes stay in the visible chord")
            #expect(chordNotes.contains { $0.isInvisible }, "the fixture must carry an invisible note")
            let sheet = PDFExporter.Sheet(
                systems: document.systems, pageStartY: 0, pageSize: CGSize(width: 572, height: 400),
                margins: PageMargins(top: 36, leading: 36, bottom: 36, trailing: 36),
            )
            let shown = try #require(PDFPageRaster.pages(of: PDFExporter.export(
                document: document, sheets: [sheet], score: score, options: .init(drawsInvisibleElements: true),
            )).first)
            let printed = try #require(PDFPageRaster.pages(of: PDFExporter.export(
                document: document, sheets: [sheet], score: score, options: .init(drawsInvisibleElements: false),
            )).first)
            let shownInk = shown.markedIndices
            let printedInk = printed.markedIndices
            #expect(printedInk.count < shownInk.count, "control: the switch has something to omit")
            let subset = printedInk.isSubset(of: shownInk)
            #expect(subset, "printing with the switch off added or moved ink")
            #expect(!printedInk.isEmpty, "the visible note and the staff must still print")
        }
    }
#endif
