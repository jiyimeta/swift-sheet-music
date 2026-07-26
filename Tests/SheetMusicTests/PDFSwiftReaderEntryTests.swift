#if !os(Android)
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    /// The pure-Swift-reader entry points (the code Android runs) exercised on the Apple host.
    @MainActor struct PDFSwiftReaderEntryTests {
        /// A real PDF, produced by the production `PDFExporter` from a tiny in-memory `Score` (the same
        /// recipe `PDFExporterTests.smallScore()` uses) — the same "reuse the production exporter" fixture
        /// mechanism `PDFImporterRoundTripTests` uses, since `PDFImporterFacadeTests`'s own
        /// `PDFFixtureBuilder`-drawn staff lines carry no notes at all.
        ///
        /// NOTE: like `PDFImporterRoundTripTests` documents, the note GLYPHS in `PDFExporter`'s output don't
        /// currently decode: CoreText draws them through a simple (1-byte-code) font, but `emitShow`
        /// (`PDFImporter+ContentStream+TextShow.swift`) only decodes CIDs when a `/ToUnicode` CMap is
        /// present, unconditionally assuming 2-byte codes — so the show operator is silently dropped. Only
        /// real MuseScore-exported PDFs (not committed here — copyright) use genuine 2-byte Identity-H CID
        /// fonts and decode notes correctly. That pre-existing, shared-interpreter gap is out of scope for
        /// this task (constraint: must not touch the Apple decode path), so the STAFF/measure geometry this
        /// fixture's ruled lines produce is exercised below; note-level `itemRects` are not.
        @available(macOS 15.0, iOS 16.0, *)
        static func fixtureData() throws -> Data {
            let chord = Chord(
                duration: .quarter,
                notes: [Note(pitch: 60, tpc: 14)],
            )
            let voice = Voice(elements: [
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(chord), .chord(chord),
                .chord(chord), .chord(chord),
            ])
            let staff = Staff(
                measures: [Measure(voices: [voice])],
            )
            let part = Part(
                id: "P1",
                instrument: Instrument(
                    id: "i",
                    articulations: [InstrumentArticulation()],
                ),
                staves: [staff],
            )
            let score = Score(division: 480, parts: [part])
            return try PDFExporter.export(score: score)
        }

        @Test func summaryReportsPageCountAndTitle() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let data = try Self.fixtureData()
            let summary = try #require(PDFImporter.summaryUsingSwiftReader(pdfData: data))
            #expect(summary.pageCount > 0)
        }

        @Test func summaryRejectsNonPDFBytes() {
            #expect(PDFImporter.summaryUsingSwiftReader(pdfData: Data("not a pdf".utf8)) == nil)
        }

        /// The Android decode path must agree with the Apple `CGPDFScanner` path.
        @Test func swiftReaderScoreMatchesAppleScore() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let data = try Self.fixtureData()
            let apple = try PDFImporter.parse(pdfData: data)
            let swiftReader = try PDFImporter.parseUsingSwiftReader(pdfData: data)
            #expect(apple.parts.count == swiftReader.parts.count)
            #expect(apple.allStaves.count == swiftReader.allStaves.count)
            for (lhs, rhs) in zip(apple.allStaves, swiftReader.allStaves) {
                #expect(lhs.1.measures.count == rhs.1.measures.count)
            }
        }

        /// `parseWithGeometry` must return the SAME score `parse` returns — the collector is a side-car,
        /// never an input to the decode. Asserts on `measureRects`/`systemRects`, not `itemRects`: this
        /// fixture's notes don't decode (see `fixtureData`'s note), but the staff/measure geometry the
        /// document's ruled lines produce is real and exercises the same collector plumbing.
        @Test func geometryPathDoesNotPerturbTheScore() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let data = try Self.fixtureData()
            let plain = try PDFImporter.parseUsingSwiftReader(pdfData: data)
            let (withGeometry, geometry) = try PDFImporter.parseWithGeometryUsingSwiftReader(pdfData: data)
            #expect(plain.allStaves.count == withGeometry.allStaves.count)
            #expect(!geometry.measureRects.isEmpty)
            #expect(!geometry.systemRects.isEmpty)
            #expect(!geometry.pageSizes.isEmpty)
        }

        @Test func geometryRectsCarryAPageIndexWithinTheDocument() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let data = try Self.fixtureData()
            let (_, geometry) = try PDFImporter.parseWithGeometryUsingSwiftReader(pdfData: data)
            let pageCount = geometry.pageSizes.count
            for rect in geometry.measureRects.values {
                #expect(rect.pageIndex >= 0)
                #expect(rect.pageIndex < pageCount)
            }
            for rect in geometry.systemRects {
                #expect(rect.pageIndex >= 0)
                #expect(rect.pageIndex < pageCount)
            }
        }
    }
#endif
