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
            /// Seam AND score level both measured — a normal `render.json`
            /// directory with a `source.mscx`.
            var scored = 0
            /// Seam level measured, score level deliberately NOT
            /// attempted because the directory has no `source.mscx` — the
            /// expected, correct state for every FROZEN (degraded)
            /// render, since `freeze` does not copy the source. Must
            /// never be folded into `failed`: that would make a healthy
            /// degraded-set run look broken.
            var seamOnly = 0
            /// Something threw that should not have.
            var failed = 0
            /// A page whose raster analysis was unavailable — no
            /// `analyses(dir:pages:)` entry for it, because its image
            /// file was missing/unreadable — and so was skipped from the
            /// seam pass entirely. Distinct from `failed`: the render as
            /// a whole may still succeed (`.seamOnly` or `.scored`) with
            /// its OTHER pages counted normally; this counter is what
            /// keeps a silently-skipped page from reading as "nothing
            /// wrong happened" in the summary line (see finding #2's
            /// `render.json` case, where a missing image is normally
            /// caught by `evaluateScore`'s throw and counted in
            /// `failed`, but a FROZEN render — no `source.mscx`, so
            /// `evaluate` returns `.seamOnly` before ever calling
            /// `evaluateScore` — has no such backstop).
            var skippedNoAnalysis = 0
            /// A page P3a found no staff on (`analysis.staffSpacingPt
            /// <= 0`, `RasterPage.analyze`'s own outcome for a staffless
            /// page, not a thrown error). `OMRDetectorMetrics.match`
            /// still counts every truth glyph on such a page into `fn`
            /// (see that type's own doc comment); this counter is the
            /// population-degradation signal the recall number alone
            /// cannot carry — a run with the same recall but a higher
            /// `noStaffPages` means P3a, not the detector, is where the
            /// score moved.
            var noStaffPages = 0
            var tpByClass: [String: Int] = [:]
            var fpByClass: [String: Int] = [:]
            var fnByClass: [String: Int] = [:]
            /// Quarter-staff-space buckets, exactly as `[endprofile]`
            /// already does — the raw list would be tens of megabytes
            /// over a real corpus.
            var originErrBuckets: [Int: Int] = [:]
            var originErrSumSp = 0.0
            var originErrCount = 0

            /// Folds another `Totals`' seam-level fields (everything
            /// `evaluate`/`evaluateSeam` populate) into this one.
            /// `scored`/`seamOnly`/`failed` are NOT included here — those
            /// are maintained only by `sweep` itself, one per render, so
            /// a render-scoped `Totals` used as an accumulation buffer
            /// (see `evaluate`) never carries a nonzero value for them.
            mutating func merge(_ other: Totals) {
                pages += other.pages
                skippedNoAnalysis += other.skippedNoAnalysis
                noStaffPages += other.noStaffPages
                for (cls, n) in other.tpByClass {
                    tpByClass[cls, default: 0] += n
                }
                for (cls, n) in other.fpByClass {
                    fpByClass[cls, default: 0] += n
                }
                for (cls, n) in other.fnByClass {
                    fnByClass[cls, default: 0] += n
                }
                for (bucket, n) in other.originErrBuckets {
                    originErrBuckets[bucket, default: 0] += n
                }
                originErrSumSp += other.originErrSumSp
                originErrCount += other.originErrCount
            }
        }

        /// One render directory's outcome, distinct from `Totals.failed`:
        /// a render with no `source.mscx` (every FROZEN render) is
        /// `.seamOnly`, not a failure. `.skipped` is the pre-existing
        /// silent-skip case (no label files at all), uncounted, matching
        /// the other OMR harnesses' `.skipped` outcome.
        enum RenderOutcome {
            case scored
            case seamOnly
            case skipped
        }

        /// The whole corpus: every render-OR-FROZEN directory
        /// (`OMRHarnessDirectoryWalk.renderOrFrozenDirectories` — the
        /// degraded eval set marks itself with `frozen.json` rather than
        /// `render.json`, deliberately, so a second `freeze` cannot
        /// re-degrade its own output; a `render.json`-only walk over it
        /// sweeps nothing while printing a plausible-looking zero, see
        /// that function's own doc comment and `OMRRasterSeamEvalTests`,
        /// which hit this exact trap first), one page's bitmap live at a
        /// time. A single render's failure — a bad label file, a page
        /// with no raster analysis under `.detectorGlyphs` (see
        /// `OMRHybridFrontEnd.compose`'s deliberate throw), a corrupt
        /// PDF — is caught, counted in `totals.failed`, and printed as
        /// `[detect][WARN]`; it never aborts the sweep, matching
        /// `OMRPrepExportHarness.sweep`.
        static func sweep(
            root: String, detector: any OMRGlyphDetecting, matchSp: Double,
        ) throws -> (renders: Int, totals: Totals, pitchPcts: [Double], durPcts: [Double]) {
            let renderDirs = try OMRHarnessDirectoryWalk.renderOrFrozenDirectories(root: root)
            var totals = Totals()
            var pitchPcts: [Double] = []
            var durPcts: [Double] = []
            for dir in renderDirs {
                autoreleasepool {
                    do {
                        switch try evaluate(
                            dir: dir, detector: detector, matchSp: matchSp,
                            into: &totals, pitchPcts: &pitchPcts, durPcts: &durPcts,
                        ) {
                        case .scored: totals.scored += 1
                        case .seamOnly: totals.seamOnly += 1
                        case .skipped: break
                        }
                    } catch {
                        totals.failed += 1
                        print("[detect][WARN] \(dir) \(error)")
                    }
                }
            }
            return (renderDirs.count, totals, pitchPcts, durPcts)
        }

        /// One render directory: seam metrics for every page that has a
        /// raster analysis (run REGARDLESS of whether `source.mscx`
        /// exists — a frozen render never has one, and the whole point
        /// of the degraded sweep is the seam number), then one
        /// score-level comparison against `source.mscx`, attempted only
        /// when that file exists.
        ///
        /// The seam pass accumulates into a RENDER-SCOPED `renderTotals`
        /// buffer, not `totals` directly, and is folded into `totals`
        /// only once this render's own outcome is known to be a success
        /// (`.seamOnly` or `.scored`) — never on the way to a throw. A
        /// render whose `source.mscx` exists but fails to parse used to
        /// leak this render's `pages`/tp/fp/fn into the running totals
        /// before `MSCXParser.parse` threw, so a render `sweep` correctly
        /// counts as `failed` still moved the seam numbers.
        static func evaluate(
            dir: String, detector: any OMRGlyphDetecting, matchSp: Double,
            into totals: inout Totals, pitchPcts: inout [Double], durPcts: inout [Double],
        ) throws -> RenderOutcome {
            let labelNames = try OMRHarnessDirectoryWalk.labelFiles(in: dir)
            guard !labelNames.isEmpty else { return .skipped }
            let pages = try labelNames.map {
                try OMRLabelSchema.decode(Data(contentsOf: URL(fileURLWithPath: "\(dir)/\($0)")))
            }
            let pageAnalyses = analyses(dir: dir, pages: pages)
            var renderTotals = Totals()
            for page in pages {
                guard let analysis = pageAnalyses[page.page.index] else {
                    renderTotals.skippedNoAnalysis += 1
                    continue
                }
                try evaluateSeam(
                    page: page, analysis: analysis, detector: detector,
                    matchSp: matchSp, into: &renderTotals,
                )
            }
            guard FileManager.default.fileExists(atPath: "\(dir)/source.mscx") else {
                totals.merge(renderTotals)
                return .seamOnly
            }
            let scoreA = try MSCXParser.parse(
                contentsOf: URL(fileURLWithPath: "\(dir)/source.mscx"),
            )
            try evaluateScore(
                dir: dir, scoreA: scoreA, pages: pages, pageAnalyses: pageAnalyses,
                detector: detector, pitchPcts: &pitchPcts, durPcts: &durPcts,
            )
            totals.merge(renderTotals)
            return .scored
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
            if analysis.staffSpacingPt <= 0 { totals.noStaffPages += 1 }
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
