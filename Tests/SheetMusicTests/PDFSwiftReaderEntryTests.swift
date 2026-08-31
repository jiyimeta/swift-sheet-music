#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
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
        /// NOTE: the note GLYPHS in `PDFExporter`'s output used not to decode at all. CoreText draws them
        /// through a SIMPLE (1-byte-code) font that also carries a `/ToUnicode` CMap, and `emitShow`
        /// (`PDFImporter+ContentStream+TextShow.swift`) inferred a 2-byte Identity-H code width from the
        /// mere presence of that CMap — so every code was read as half a CID and silently dropped. The show
        /// path now takes its code width from the font's `/Subtype`, and this fixture's notes decode.
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
