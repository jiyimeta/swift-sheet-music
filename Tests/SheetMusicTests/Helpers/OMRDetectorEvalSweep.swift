#if !os(Android)
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicMSCX
    @testable import SheetMusicPDF

    /// The `OMR_DETECT_EVAL=1` sweep's pure machinery (task 16): per
    /// render, per page seam metrics against the label glyphs
    /// (`OMRDetectorMetrics`), then the score-level comparison against
    /// `source.mscx` reusing `ScoreSemanticMetrics` — the same metric
    /// functions `OMRHybridEvalHarness` uses, composed here with
    /// `mode: .detectorGlyphs` and a real detector instead of the label
    /// oracle, so the two harnesses' numbers stay directly comparable.
    ///
    /// Factored out of `OMRDetectorEvalHarness`'s `@Test` body (mirroring
    /// every other OMR harness's `evaluate`/`sweep` split) so
    /// `OMRDetectorEvalWiringTests` can drive it with a fake detector and
    /// synthetic directories, needing neither `OMR_DATA_ROOT` nor
    /// `OMR_MODEL_ROOT`.
    @MainActor
    enum OMRDetectorEvalSweep {
        struct Totals {
            var pages = 0
            var failed = 0
            var tpByClass: [String: Int] = [:]
            var fpByClass: [String: Int] = [:]
            var fnByClass: [String: Int] = [:]
            /// Quarter-staff-space buckets, exactly as `[endprofile]`
            /// already does — the raw list would be tens of megabytes
            /// over a real corpus.
            var originErrBuckets: [Int: Int] = [:]
            var originErrSumSp = 0.0
            var originErrCount = 0
        }

        /// The whole corpus: every render directory
        /// (`OMRHarnessDirectoryWalk.renderDirectories`), one page's
        /// bitmap live at a time. A single render's failure — a bad
        /// label file, a page with no raster analysis under
        /// `.detectorGlyphs` (see `OMRHybridFrontEnd.compose`'s
        /// deliberate throw), a corrupt PDF — is caught, counted in
        /// `totals.failed`, and printed as `[detect][WARN]`; it never
        /// aborts the sweep, matching `OMRPrepExportHarness.sweep`.
        static func sweep(
            root: String, detector: any OMRGlyphDetecting, matchSp: Double,
        ) throws -> (renders: Int, totals: Totals, pitchPcts: [Double], durPcts: [Double]) {
            let renderDirs = try OMRHarnessDirectoryWalk.renderDirectories(root: root)
            var totals = Totals()
            var pitchPcts: [Double] = []
            var durPcts: [Double] = []
            for dir in renderDirs {
                autoreleasepool {
                    do {
                        try evaluate(
                            dir: dir, detector: detector, matchSp: matchSp,
                            into: &totals, pitchPcts: &pitchPcts, durPcts: &durPcts,
                        )
                    } catch {
                        totals.failed += 1
                        print("[detect][WARN] \(dir) \(error)")
                    }
                }
            }
            return (renderDirs.count, totals, pitchPcts, durPcts)
        }

        /// One render directory: seam metrics for every page that has a
        /// raster analysis, then one score-level comparison against
        /// `source.mscx` over the whole render.
        static func evaluate(
            dir: String, detector: any OMRGlyphDetecting, matchSp: Double,
            into totals: inout Totals, pitchPcts: inout [Double], durPcts: inout [Double],
        ) throws {
            let labelNames = try OMRHarnessDirectoryWalk.labelFiles(in: dir)
            guard FileManager.default.fileExists(atPath: "\(dir)/source.mscx"), !labelNames.isEmpty
            else { return }
            let scoreA = try MSCXParser.parse(
                contentsOf: URL(fileURLWithPath: "\(dir)/source.mscx"),
            )
            let pages = try labelNames.map {
                try OMRLabelSchema.decode(Data(contentsOf: URL(fileURLWithPath: "\(dir)/\($0)")))
            }
            let pageAnalyses = analyses(dir: dir, pages: pages)
            for page in pages {
                guard let analysis = pageAnalyses[page.page.index] else { continue }
                try evaluateSeam(
                    page: page, analysis: analysis, detector: detector,
                    matchSp: matchSp, into: &totals,
                )
            }
            try evaluateScore(
                dir: dir, scoreA: scoreA, pages: pages, pageAnalyses: pageAnalyses,
                detector: detector, pitchPcts: &pitchPcts, durPcts: &durPcts,
            )
        }

        /// Every page's raster analysis, `keepDeskewed: true` — the
        /// detector needs the deskewed bitmap
        /// (`OMRDetectorFrontEnd.glyphs` returns `[]` without it), unlike
        /// `OMRHybridEvalHarness.analyses`, which does not keep it. One
        /// bitmap live at a time via `OMRPageBitmapLoader`, the only
        /// sanctioned way a sweep touches a page image.
        private static func analyses(
            dir: String, pages: [OMRPageLabels],
        ) -> [Int: RasterPageAnalysis] {
            var out: [Int: RasterPageAnalysis] = [:]
            for page in pages {
                let url = URL(fileURLWithPath: "\(dir)/\(page.image.file)")
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                out[page.page.index] = try? OMRPageBitmapLoader.withPageBitmap(
                    url: url, dpi: Double(page.image.dpi),
                ) { RasterPage.analyze($0, pageIndex: page.page.index, keepDeskewed: true) }
            }
            return out
        }

        /// One page's seam-level match: the detector's own output
        /// against the label glyphs, reframed into the front-end's frame
        /// and restricted to the detector vocabulary — exactly the
        /// `vocabulary` `OMRHybridFrontEnd.compose` builds internally
        /// for `.detectorGlyphs` before reframing, recomputed here since
        /// `compose` does not expose it to a caller.
        private static func evaluateSeam(
            page: OMRPageLabels, analysis: RasterPageAnalysis,
            detector: any OMRGlyphDetecting, matchSp: Double, into totals: inout Totals,
        ) throws {
            totals.pages += 1
            let oracle = try OMROracleFrontEnd.replay(pages: [page])
            let vocabulary = OMRHybridFrontEnd.detectorVocabularyGlyphs(
                oracle.walked.glyphs.filter { $0.geometry.pageIndex == page.page.index },
            )
            let truth = OMRHybridFrontEnd.reframe(vocabulary, page: page, transform: analysis.transform)
            let predicted = try detector.glyphs(page: page, analysis: analysis)
            let result = OMRDetectorMetrics.match(
                predicted: predicted, truth: truth,
                staffSpacingPt: analysis.staffSpacingPt, matchSp: matchSp,
            )
            for (cls, counts) in result.byClass {
                totals.tpByClass[cls, default: 0] += counts.tp
                totals.fpByClass[cls, default: 0] += counts.fp
                totals.fnByClass[cls, default: 0] += counts.fn
                for err in counts.originErrSp {
                    totals.originErrBuckets[Int((err * 4).rounded(.down)), default: 0] += 1
                    totals.originErrSumSp += err
                    totals.originErrCount += 1
                }
            }
        }

        /// The render's score-level number: `.detectorGlyphs` composed
        /// with the SAME analyses the seam pass already computed (so a
        /// page's raster is analyzed once, not twice), then `buildScore`
        /// vs `source.mscx` through `ScoreSemanticMetrics` — the exact
        /// metric functions `OMRHybridEvalHarness` uses, so the two
        /// harnesses' numbers stay comparable.
        private static func evaluateScore(
            dir: String, scoreA: Score, pages: [OMRPageLabels],
            pageAnalyses: [Int: RasterPageAnalysis], detector: any OMRGlyphDetecting,
            pitchPcts: inout [Double], durPcts: inout [Double],
        ) throws {
            let hybrid = try OMRHybridFrontEnd.compose(
                pages: pages, analyses: pageAnalyses, mode: .detectorGlyphs, detector: detector,
            )
            let scoreB = try PDFImporter.buildScore(
                pageCount: hybrid.pageCount, walked: hybrid.walked,
                pageSizes: hybrid.pageSizes, documentAttributes: nil,
                options: PDFImportOptions(),
            )
            let aligned = ScoreSemanticMetrics.alignNotefulParts(scoreA: scoreA, scoreB: scoreB)
            print(ScoreSemanticMetrics.summaryRow(
                tag: "[\((dir as NSString).lastPathComponent)]", scoreA: scoreA, scoreB: scoreB,
                pdfRecovered: true, aligned: aligned, hiddenLoss: 0,
            ))
            let pitchRes = ScoreSemanticMetrics.measureAlignedPitchMatch(
                scoreA: aligned.scoreA, scoreB: aligned.scoreB,
            )
            if pitchRes.pos.c > 0 {
                pitchPcts.append(Double(pitchRes.pos.m) / Double(pitchRes.pos.c))
            }
            let durRes = ScoreSemanticMetrics.measureAlignedDurationMatch(
                scoreA: aligned.scoreA, scoreB: aligned.scoreB,
            )
            if durRes.match.c > 0 {
                durPcts.append(Double(durRes.match.m) / Double(durRes.match.c))
            }
        }
    }
#endif
