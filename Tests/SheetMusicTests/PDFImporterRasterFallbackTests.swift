#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    import SheetMusicOMRModel
    @testable import SheetMusicPDF
    import Testing

    /// The public tap: `PDFImportOptions.omrTileClassifier` turning
    /// `PDFImporter.parse` into something that can read a scanned page, and
    /// the per-page gate that decides which pages it reads.
    struct PDFImporterRasterFallbackTests {
        // MARK: - Tests

        /// G3a: with a classifier set, an image-only PDF reaches `buildScore`.
        /// Without one, it does not — which is what makes the knob meaningful.
        @Test func anImageOnlyPageIsReadOnlyWhenAClassifierIsSet() async throws {
            let data = try Self.imageOnlyPDF(Self.staffBitmap())
            #expect(throws: (any Error).self) {
                try PDFImporter.parse(pdfData: data, options: PDFImportOptions())
            }

            var options = PDFImportOptions()
            options.omrTileClassifier = try await CoreMLTileClassifier()
            options.omrRenderDPI = Self.renderDPI
            let score = try PDFImporter.parse(pdfData: data, options: options)
            #expect(!score.parts.isEmpty)
        }

        /// The per-page gate, in both directions. A page the vector walker
        /// filled must NOT reach the detector; a page it left empty MUST.
        ///
        /// Both directions matter: asserting only "not asked" would pass even
        /// if the fallback were deleted outright, and a test that cannot fail
        /// is this repository's most-recorded defect class.
        @Test func theDetectorIsAskedOnlyForPagesWithNoVectorContent() throws {
            // Fixture construction stays OUTSIDE the `try?`: swallowing a
            // `FixtureError` there would let the vector half pass because no
            // document was ever parsed.
            let vectorData = try Self.vectorPDF()
            let imageData = try Self.imageOnlyPDF(Self.staffBitmap())

            let onVector = Tripwire()
            var vectorOptions = PDFImportOptions()
            vectorOptions.omrDetector = onVector
            vectorOptions.omrRenderDPI = Self.renderDPI
            _ = try? PDFImporter.parse(pdfData: vectorData, options: vectorOptions)
            #expect(onVector.pagesAsked.isEmpty, "a page with vector content must not be rasterized")

            let onImage = Tripwire()
            var imageOptions = PDFImportOptions()
            imageOptions.omrDetector = onImage
            imageOptions.omrRenderDPI = Self.renderDPI
            _ = try? PDFImporter.parse(pdfData: imageData, options: imageOptions)
            #expect(onImage.pagesAsked == [0], "an image-only page must reach the detector exactly once")
        }

        /// `nil` means today's behavior LITERALLY: no rasterization, no
        /// detection, no new pass over the pages. The corpus gate is only
        /// meaningful because of this, so it is asserted directly rather than
        /// inferred from the corpus staying byte-identical.
        ///
        /// A detector that was never injected cannot witness this — a
        /// tripwire nobody handed to the importer reports "not asked" however
        /// the importer behaves. So the invariant is asserted where it is
        /// actually decided (`rasterDetector(for:)` returning `nil`) and where
        /// it is actually observable (the default parse says exactly the one
        /// thing it has always said — a new pass over the pages would show up
        /// here as extra chatter even if it changed no output).
        @Test func noClassifierAndNoDetectorEntersNoNewCodePath() throws {
            let data = try Self.imageOnlyPDF(Self.staffBitmap())

            #expect(try PDFImporter.rasterDetector(for: PDFImportOptions()) == nil)

            let log = DiagnosticLog()
            var defaults = PDFImportOptions()
            defaults.diagnostics = { log.messages.append($0.message) }
            #expect(throws: (any Error).self) {
                try PDFImporter.parse(pdfData: data, options: defaults)
            }
            #expect(log.messages.count == 1, "the default path must not gain any new diagnostic")
            #expect(log.messages.first?.contains("omrTileClassifier") == true)
            #expect(
                !log.messages.contains { $0.hasPrefix("OMR:") },
                "no diagnostic may come from the raster path when it was never entered",
            )

            // The contrast, so none of the above passes merely because the
            // machinery is absent: the SAME document does reach a detector
            // once one is configured.
            let tripwire = Tripwire()
            var configured = PDFImportOptions()
            configured.omrDetector = tripwire
            configured.omrRenderDPI = Self.renderDPI
            _ = try? PDFImporter.parse(pdfData: data, options: configured)
            #expect(tripwire.pagesAsked == [0], "the injected detector is what makes the page readable")
        }

        /// G3c: one vector page and one image-only page in the same document.
        /// The vector page's own reading must be unchanged from parsing it
        /// alone — `buildScore` derives ONE document-wide ensemble staff count
        /// as a GCD over every page, so a raster page that miscounts can drop
        /// every page, vector ones included, onto the per-page heuristic.
        @Test func aMixedDocumentLeavesTheVectorPageUnchanged() async throws {
            var options = PDFImportOptions()
            options.omrTileClassifier = try await CoreMLTileClassifier()
            options.omrRenderDPI = Self.renderDPI
            let mixed = try PDFImporter.parse(pdfData: Self.mixedPDF(), options: options)
            let vectorAlone = try PDFImporter.parse(
                pdfData: Self.vectorPDF(), options: PDFImportOptions(),
            )
            #expect(mixed.parts.count == vectorAlone.parts.count)
            // The vector page is page 0 of both documents, so its measures are
            // the PREFIX of the mixed document's. Comparing totals instead
            // would only pass while the raster page contributes nothing —
            // i.e. it would pass for the wrong reason.
            let mixedMeasures = try #require(mixed.parts.first?.staves.first?.measures)
            let aloneMeasures = try #require(vectorAlone.parts.first?.staves.first?.measures)
            #expect(!aloneMeasures.isEmpty, "the vector page must read as at least one measure")
            #expect(
                mixedMeasures.count > aloneMeasures.count,
                "the raster page must contribute measures of its own, or this test passes blind",
            )
            #expect(
                Self.ignoringBreaks(Array(mixedMeasures.prefix(aloneMeasures.count)))
                    == Self.ignoringBreaks(aloneMeasures),
            )
        }

        /// The precondition `aMixedDocumentLeavesTheVectorPageUnchanged`
        /// depends on and cannot state for itself: BOTH fixture pages must
        /// detect two staves, so the document-wide GCD is a real ensemble
        /// (2) rather than the `nil` a one-staff-per-page fixture would leave
        /// it at. Without this, the mixed-document test still passes but
        /// exercises none of the coupling it exists for — so the fixture is
        /// measured here rather than assumed from its constants.
        @Test func bothFixturePagesCarryATwoStaffEnsemble() throws {
            let document = try PDFImporter.openDocument(Self.vectorPDF())
            let walk = try PDFImporter.walkDocument(document)
            let vectorStaves = PDFImporter.detectStaves(
                paths: walk.content.paths, classified: walk.content.glyphs, pageIndex: 0,
            )
            #expect(vectorStaves.count == 2, "the vector fixture page must carry two staves")

            // The raster page's staves come from the same classical-CV paths
            // the fallback merges, so they are measured the same way.
            let analysis = RasterPage.analyze(Self.staffBitmap(), pageIndex: 0)
            let rasterStaves = PDFImporter.detectStaves(
                paths: analysis.paths, classified: [], pageIndex: 0,
            )
            #expect(rasterStaves.count == 2, "the raster fixture page must carry two staves")

            #expect(
                PDFImporter.ensembleStaffCount([vectorStaves, rasterStaves]) == 2,
                "the mixed document must have a non-collapsed ensemble to lose",
            )
        }

        /// The coupling mechanism itself, directly — so a failure names the
        /// cause instead of pointing at a document-level symptom.
        @Test func oneMiscountingPageCollapsesTheEnsembleGCD() {
            let eight = Self.detectedStaves(8)
            let seven = Self.detectedStaves(7)
            #expect(PDFImporter.ensembleStaffCount([eight, eight]) == 8)
            #expect(
                PDFImporter.ensembleStaffCount([eight, seven]) == nil,
                "GCD(8,7)=1, which the importer reports as no usable ensemble",
            )
        }

        /// One page the fallback cannot read must not fail the document. The
        /// fallback is an ENHANCEMENT over pages the importer was going to
        /// contribute nothing for, so a failure there has to degrade to
        /// today's outcome for that page — otherwise setting
        /// `omrTileClassifier` on a mixed 200-page document turns a parse that
        /// succeeded on its vector pages into a total failure over one page.
        @Test func aPageTheFallbackCannotReadDoesNotFailTheDocument() throws {
            let log = DiagnosticLog()
            var options = PDFImportOptions()
            options.omrDetector = FailingDetector()
            options.omrRenderDPI = Self.renderDPI
            options.diagnostics = { log.messages.append($0.message) }

            let score = try PDFImporter.parse(pdfData: Self.mixedPDF(), options: options)
            #expect(!score.parts.isEmpty, "the vector page must still be imported")
            #expect(
                log.messages.contains { $0.contains("could not be read as an image") },
                "the page the fallback dropped must say so",
            )
        }

        /// `omrRenderDPI` is public and takes any `Double`;
        /// `PDFPageRasterizer` clamps its pixel dimensions with `max(1, …)`,
        /// so 0 would rasterize a 1x1 page whose only symptom is a downstream
        /// "no staff detected".
        @Test func anUnusableRenderDPIIsClampedAndNamed() {
            let log = DiagnosticLog()
            var options = PDFImportOptions()
            options.omrDetector = Tripwire()
            options.omrRenderDPI = 0
            options.diagnostics = { log.messages.append($0.message) }
            _ = try? PDFImporter.parse(
                pdfData: Self.imageOnlyPDF(Self.staffBitmap()), options: options,
            )
            #expect(log.messages.contains { $0.contains("omrRenderDPI is 0.0") })

            var sane = PDFImportOptions()
            sane.omrRenderDPI = Self.renderDPI
            #expect(PDFImporter.renderDPI(for: sane) == Self.renderDPI)
            #expect(PDFImporter.renderDPI(for: PDFImportOptions()) == 300)
        }

        /// §9: a page the importer cannot read must say why, and name the knob.
        @Test func anUnreadableImagePageNamesTheKnob() throws {
            let log = DiagnosticLog()
            var options = PDFImportOptions()
            options.diagnostics = { log.messages.append($0.message) }
            var thrown: String?
            do {
                _ = try PDFImporter.parse(
                    pdfData: Self.imageOnlyPDF(Self.staffBitmap()), options: options,
                )
            } catch let SheetMusicError.malformedScore(fault) {
                thrown = fault.message
            }
            #expect(log.messages.contains { $0.contains("omrTileClassifier") })
            #expect(thrown?.contains("omrTileClassifier") == true)
        }

        /// `parseWithGeometry` reads an image-only page the way `parse` does —
        /// a host that displays the source PDF (the one caller of this entry
        /// point) is exactly the host holding a scan. The geometry side-car,
        /// though, has no producer for a raster page: its rects would sit in
        /// the analysis frame, not the displayed page's, and a cursor that is
        /// silently a few points off is worse than none. So the page
        /// contributes NO rects, and the importer says so.
        @Test func theGeometryEntryPointReadsAnImageOnlyPageWithoutGeometry() async throws {
            let log = DiagnosticLog()
            var options = PDFImportOptions()
            options.omrTileClassifier = try await CoreMLTileClassifier()
            options.omrRenderDPI = Self.renderDPI
            options.diagnostics = { log.messages.append($0.message) }
            let result = try PDFImporter.parseWithGeometry(
                pdfData: Self.imageOnlyPDF(Self.staffBitmap()), options: options,
            )
            #expect(!result.score.parts.isEmpty)
            #expect(result.geometry.itemRects.isEmpty)
            #expect(result.geometry.measureRects.isEmpty)
            #expect(result.geometry.systemRects.isEmpty)
            #expect(result.geometry.pageSizes.isEmpty)
            #expect(log.messages.contains { $0.contains("no geometry") })
            #expect(!log.messages.contains { $0.contains("does not rasterize") })
        }

        /// The vector page of a mixed document keeps exactly the geometry it
        /// has when parsed alone, and the raster page adds none — so the
        /// exclusion is per page, not a document-wide switch that would take
        /// the cursor off the typeset pages around one scan.
        @Test func aMixedDocumentKeepsOnlyTheVectorPagesGeometry() async throws {
            var options = PDFImportOptions()
            options.omrTileClassifier = try await CoreMLTileClassifier()
            options.omrRenderDPI = Self.renderDPI
            let mixed = try PDFImporter.parseWithGeometry(pdfData: Self.mixedPDF(), options: options)
            let alone = try PDFImporter.parseWithGeometry(
                pdfData: Self.vectorPDF(), options: PDFImportOptions(),
            )
            #expect(!alone.geometry.measureRects.isEmpty, "the vector page must carry geometry, or this passes blind")
            let pages = Set(mixed.geometry.systemRects.map(\.pageIndex))
                .union(mixed.geometry.measureRects.values.map(\.pageIndex))
                .union(mixed.geometry.itemRects.values.map(\.pageIndex))
            #expect(pages == [0])
            #expect(mixed.geometry.systemRects == alone.geometry.systemRects)
            #expect(mixed.geometry.measureRects == alone.geometry.measureRects)
            #expect(mixed.geometry.pageSizes == alone.geometry.pageSizes)
        }

        /// The pure-Swift reader takes the same options and does nothing with
        /// this one. A knob that silently does nothing is this repository's
        /// own silent-drop smell, so that entry point says so.
        @Test func theSwiftReaderEntryPointSaysItDoesNotRasterize() async throws {
            let log = DiagnosticLog()
            var options = PDFImportOptions()
            options.omrTileClassifier = try await CoreMLTileClassifier()
            options.diagnostics = { log.messages.append($0.message) }
            _ = try? PDFImporter.parseUsingSwiftReader(
                pdfData: Self.imageOnlyPDF(Self.staffBitmap()), options: options,
            )
            #expect(log.messages.contains { $0.contains("does not rasterize") })
        }
    }
#endif
