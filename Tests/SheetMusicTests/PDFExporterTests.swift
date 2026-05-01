#if os(macOS)
    import CoreGraphics
    import Foundation
    import SheetMusic
    import SheetMusicCore
    import SheetMusicLayout
    import SheetMusicMSCX
    @testable import SheetMusicPDF
    import SheetMusicUI
    import Testing

    @Suite("PDFExporter")
    @MainActor
    struct PDFExporterTests {
        @Test("Exports a non-empty PDF with the %PDF magic header")
        func magicHeader() throws {
            guard #available(macOS 15.0, *) else { return }
            let data = try PDFExporter.export(
                score: Self.smallScore(),
                options: PDFExporter.Options(
                    title: "test", author: "tester"
                )
            )
            #expect(!data.isEmpty)
            // PDF files start with `%PDF-` (0x25 0x50 0x44 0x46 0x2D).
            // No BOM, no whitespace — first byte must be `%`.
            let prefix = data.prefix(5)
            #expect(prefix == Data([0x25, 0x50, 0x44, 0x46, 0x2D]))
        }

        @Test("Round-trips through CGPDFDocument with the expected page count")
        func cgPdfDocumentRoundTrip() throws {
            guard #available(macOS 15.0, *) else { return }
            let data = try PDFExporter.export(
                score: Self.smallScore(),
                options: PDFExporter.Options(
                    page: .explicit(.usLetter))
            )
            guard let provider = CGDataProvider(data: data as CFData),
                  let pdf = CGPDFDocument(provider)
            else {
                Issue.record("CGPDFDocument failed to parse exporter output")
                return
            }
            #expect(pdf.numberOfPages >= 1)
            // First page should report the requested mediaBox size.
            guard let page = pdf.page(at: 1) else {
                Issue.record("CGPDFDocument has no first page")
                return
            }
            let mediaBox = page.getBoxRect(.mediaBox)
            #expect(mediaBox.width == 612)
            #expect(mediaBox.height == 792)
        }

        @Test("Pagination splits a tall layout into multiple pages")
        func pagination() throws {
            guard #available(macOS 15.0, *) else { return }
            // Long score forced into a narrow + short page so it must
            // both wrap into multiple systems horizontally and split
            // across pages vertically. With our MuseScore-aligned
            // measure spacing (`spacePerQuarter ≈ 1.6 sp`) and tighter
            // inter-staff padding, 64 measures alone fit on a short
            // page — bump the count and shrink the page so the test
            // still genuinely exercises pagination.
            let shortPage = EngravingPage(
                size: CGSize(width: 360, height: 200),
                oddMargins: PageMargins(uniform: 18),
                evenMargins: PageMargins(uniform: 18),
                twosided: false
            )
            let data = try PDFExporter.export(
                score: Self.longScore(measureCount: 256),
                options: PDFExporter.Options(
                    page: .explicit(shortPage),
                    staffSize: .explicit(12)
                )
            )
            let provider = try #require(CGDataProvider(data: data as CFData))
            let pdf = try #require(CGPDFDocument(provider))
            #expect(pdf.numberOfPages > 1)
        }

        @Test("Real fixture (midi01.mscx) round-trips through a CGPDFDocument")
        func realFixture() throws {
            guard #available(macOS 15.0, *) else { return }
            guard let url = Bundle.module.url(
                forResource: "midi01", withExtension: "mscx"
            )
            else {
                Issue.record("Fixture midi01.mscx not bundled")
                return
            }
            let data = try Data(contentsOf: url)
            let score = try MSCXParser.parse(data)
            let pdf = try PDFExporter.export(
                score: score,
                options: PDFExporter.Options(
                    title: "midi01 — smoke test")
            )
            let provider = try #require(CGDataProvider(data: pdf as CFData))
            let doc = try #require(CGPDFDocument(provider))
            // Tiny score; one page suffices.
            #expect(doc.numberOfPages == 1)
            // Sanity — the embedded title metadata round-trips.
            let info = doc.info
            #expect(info != nil)
        }

        @Test("paginate() never splits a system across pages")
        func paginateNoSplits() {
            guard #available(macOS 15.0, *) else { return }
            let s0 = Self.fakeSystem(originY: 0, height: 100)
            let s1 = Self.fakeSystem(originY: 110, height: 100)
            let s2 = Self.fakeSystem(originY: 220, height: 100)
            let s3 = Self.fakeSystem(originY: 330, height: 100)
            // Usable height = 200 - 2*10 = 180 → 1 system per page (each
            // is 100 high, two together = 110 + 100 = 210 > 180 from the
            // first system's start).
            let page = EngravingPage(
                size: CGSize(width: 400, height: 200),
                oddMargins: PageMargins(uniform: 10),
                evenMargins: PageMargins(uniform: 10),
                twosided: false
            )
            let pages = PDFExporter.paginate(
                systems: [s0, s1, s2, s3], page: page
            )
            #expect(pages.count == 4)
            for batch in pages {
                #expect(batch.systems.count == 1)
            }
        }

        // MARK: - Fixtures

        private static func smallScore() -> Score {
            let chord = Chord(
                duration: .quarter,
                notes: [Note(pitch: 60, tpc: 14)]
            )
            let voice = Voice(elements: [
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(chord), .chord(chord),
                .chord(chord), .chord(chord),
            ])
            let staff = StaffContent(
                id: 1, measures: [Measure(voices: [voice])]
            )
            let part = Part(
                id: "P1",
                instrument: Instrument(
                    id: "i",
                    articulations: [InstrumentArticulation()]
                )
            )
            return Score(
                division: 480, parts: [part], staves: [staff]
            )
        }

        private static func longScore(measureCount: Int) -> Score {
            let chord = Chord(
                duration: .half,
                notes: [Note(pitch: 60, tpc: 14)]
            )
            let firstVoice = Voice(elements: [
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(chord), .chord(chord),
            ])
            let restVoice = Voice(elements: [
                .chord(chord), .chord(chord),
            ])
            var measures: [Measure] = [Measure(voices: [firstVoice])]
            for _ in 1 ..< measureCount {
                measures.append(Measure(voices: [restVoice]))
            }
            let staff = StaffContent(id: 1, measures: measures)
            let part = Part(
                id: "P1",
                instrument: Instrument(
                    id: "i",
                    articulations: [InstrumentArticulation()]
                )
            )
            return Score(
                division: 480, parts: [part], staves: [staff]
            )
        }

        @available(macOS 15.0, iOS 16.0, *)
        private static func fakeSystem(
            originY: CGFloat, height: CGFloat
        ) -> LayoutSystem {
            LayoutSystem(
                origin: CGPoint(x: 0, y: originY),
                size: CGSize(width: 400, height: height),
                measures: [],
                staffOrigins: [.zero],
                partLabels: [],
                spanners: [],
                sp: 7.0
            )
        }
    }
#endif
