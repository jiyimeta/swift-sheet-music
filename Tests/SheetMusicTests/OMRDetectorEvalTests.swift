#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicMSCX
    @testable import SheetMusicPDF
    import Testing

    /// Detector seam-metric unit tests (task 16 brief, step 1). Run via
    /// `swift test --filter OMRDetectorEvalFixtureTests` — no
    /// `OMR_DATA_ROOT` / `OMR_MODEL_ROOT` needed, since
    /// `OMRDetectorMetrics.match` is a pure function over hand-built
    /// `ClassifiedGlyph`s.
    struct OMRDetectorEvalFixtureTests {
        static let staffSpacingPt = 8.0

        static func glyph(_ semantic: SMuFLSemantic, x: CGFloat, y: CGFloat) -> ClassifiedGlyph {
            ClassifiedGlyph(
                geometry: GlyphGeometry(
                    origin: CGPoint(x: x, y: y), advance: 6, renderedSize: 5,
                    pageIndex: 0, fontSize: 0,
                ),
                semantic: semantic,
            )
        }

        /// Feed the label glyphs back as detections: recall and
        /// precision must both be 1.0 and the origin error identically
        /// 0. A metric that cannot say "perfect" for a perfect detector
        /// cannot be trusted to say anything about an imperfect one.
        @Test func theSeamMetricScoresAPerfectDetectorAtOne() {
            let truth = [
                Self.glyph(.noteheadBlack, x: 100, y: 200),
                Self.glyph(.clefG, x: 50, y: 150),
            ]
            let result = OMRDetectorMetrics.match(
                predicted: truth, truth: truth,
                staffSpacingPt: Self.staffSpacingPt, matchSp: 0.5,
            )
            #expect(abs(result.recall - 1.0) < 1e-9)
            #expect(abs(result.precision - 1.0) < 1e-9)
            #expect(result.originErrorSpacesP50 == 0)
        }

        /// The default radius (`matchSp` 0.5 staff spaces = 4pt at this
        /// spacing) is a hard boundary, not a soft preference: a
        /// detection 5pt away must score a miss on BOTH sides — one fp
        /// (the spurious detection), one fn (the truth nothing
        /// claimed) — never a distant match.
        @Test func aDetectionOffByMoreThanTheRadiusIsNotAMatch() {
            let truth = [Self.glyph(.noteheadBlack, x: 100, y: 200)]
            let predicted = [Self.glyph(.noteheadBlack, x: 105, y: 200)]
            let result = OMRDetectorMetrics.match(
                predicted: predicted, truth: truth,
                staffSpacingPt: Self.staffSpacingPt, matchSp: 0.5,
            )
            #expect(result.tp == 0)
            #expect(result.fp == 1)
            #expect(result.fn == 1)
        }

        /// Two predictions on one truth must score one tp and one fp,
        /// never two tps — otherwise precision is unbounded above (a
        /// detector emitting ten copies of every real notehead would
        /// read as flawless).
        @Test func matchingIsOneToOneWithinAClass() {
            let truth = [Self.glyph(.noteheadBlack, x: 100, y: 200)]
            let predicted = [
                Self.glyph(.noteheadBlack, x: 100, y: 200),
                Self.glyph(.noteheadBlack, x: 101, y: 200),
            ]
            let result = OMRDetectorMetrics.match(
                predicted: predicted, truth: truth,
                staffSpacingPt: Self.staffSpacingPt, matchSp: 0.5,
            )
            #expect(result.tp == 1)
            #expect(result.fp == 1)
            #expect(result.fn == 0)
        }

        /// The discrimination check the perfect-detector test alone
        /// cannot provide: a metric that unconditionally returned
        /// 1.0/1.0/0 would still pass
        /// `theSeamMetricScoresAPerfectDetectorAtOne`. Perturbing one
        /// predicted origin by 1pt (within the 4pt radius, so it still
        /// counts as a match) must move recall not at all but push
        /// `originErrorSpacesP50` strictly positive; reverting to the
        /// exact label origins must bring it back to exactly 0.
        @Test func perturbingAPredictedOriginMovesTheOriginErrorAndRevertingRestoresIt() {
            let truth = [
                Self.glyph(.noteheadBlack, x: 100, y: 200),
                Self.glyph(.clefG, x: 50, y: 150),
            ]
            let perfect = OMRDetectorMetrics.match(
                predicted: truth, truth: truth,
                staffSpacingPt: Self.staffSpacingPt, matchSp: 0.5,
            )
            #expect(perfect.originErrorSpacesP50 == 0)

            var perturbed = truth
            perturbed[0].geometry.origin.x += 1
            let moved = OMRDetectorMetrics.match(
                predicted: perturbed, truth: truth,
                staffSpacingPt: Self.staffSpacingPt, matchSp: 0.5,
            )
            #expect(abs(moved.recall - 1.0) < 1e-9)
            #expect(moved.originErrorSpacesP50 > 0)

            let reverted = OMRDetectorMetrics.match(
                predicted: truth, truth: truth,
                staffSpacingPt: Self.staffSpacingPt, matchSp: 0.5,
            )
            #expect(reverted.originErrorSpacesP50 == 0)
        }
    }

    /// Seam + score sweep over `OMR_DATA_ROOT` with a REAL detector
    /// (design spec §8.1/§8.2, task 16). No-op unless `OMR_DETECT_EVAL=1`
    /// — no trained model exists on this machine yet, so this suite has
    /// never executed end-to-end here; only its pure machinery
    /// (`OMRDetectorMetrics`, `OMRDetectorEvalSweep`) has, via the
    /// fixture tests above and `OMRDetectorEvalWiringTests` below. Run
    /// it in RELEASE, same reasoning as `OMRRasterSeamEvalHarness`.
    ///
    ///     OMR_DATA_ROOT=~/Datasets/sheet-music-omr/v2 \
    ///     OMR_MODEL_ROOT=~/Datasets/sheet-music-omr/model \
    ///     ~/.claude/bin/run-with-memcap.sh 4000 /tmp/detect-eval.log \
    ///         env OMR_DETECT_EVAL=1 swift test -c release --no-parallel \
    ///         --filter OMRDetectorEvalHarness
    @Suite(.enabled(if: ProcessInfo.processInfo.environment["OMR_DETECT_EVAL"] == "1"))
    struct OMRDetectorEvalHarness {
        static func matchSp() -> Double {
            Double(ProcessInfo.processInfo.environment["OMR_DETECT_MATCH_SP"] ?? "") ?? 0.5
        }

        @MainActor
        @Test func detectorAgainstLabelsAndSourceMscx() async throws {
            guard let root = ProcessInfo.processInfo.environment["OMR_DATA_ROOT"] else {
                Issue.record("OMR_DETECT_EVAL=1 but OMR_DATA_ROOT is unset")
                return
            }
            guard let modelPath = ProcessInfo.processInfo.environment["OMR_MODEL_ROOT"] else {
                Issue.record("OMR_DETECT_EVAL=1 but OMR_MODEL_ROOT is unset")
                return
            }
            let detector = try await OMRDetectorFrontEnd(
                modelRoot: URL(fileURLWithPath: modelPath, isDirectory: true),
            )
            let result = try OMRDetectorEvalSweep.sweep(
                root: root, detector: detector, matchSp: Self.matchSp(),
            )
            Self.printSeamSummary(totals: result.totals)
            Self.printScoreSummary(
                renders: result.renders, scored: result.totals.scored,
                seamOnly: result.totals.seamOnly, failed: result.totals.failed,
                pitchPcts: result.pitchPcts, durPcts: result.durPcts,
            )
        }

        static func printSeamSummary(totals: OMRDetectorEvalSweep.Totals) {
            let tp = totals.tpByClass.values.reduce(0, +)
            let fp = totals.fpByClass.values.reduce(0, +)
            let fn = totals.fnByClass.values.reduce(0, +)
            let recall = (tp + fn) > 0 ? Double(tp) / Double(tp + fn) : 0
            let precision = (tp + fp) > 0 ? Double(tp) / Double(tp + fp) : 0
            let meanErr = totals.originErrCount > 0
                ? totals.originErrSumSp / Double(totals.originErrCount) : 0
            print(
                "[detect-seam][SUMMARY] pages=\(totals.pages) "
                    + "tp=\(tp) fp=\(fp) fn=\(fn) "
                    + "recall=\(String(format: "%.4f", recall)) "
                    + "precision=\(String(format: "%.4f", precision)) "
                    + "meanOriginErrSp=\(String(format: "%.4f", meanErr)) "
                    + "peakRSS=\(OMRPageBitmapLoader.peakResidentMB())MB",
            )
            let classes = Set(totals.tpByClass.keys)
                .union(totals.fpByClass.keys).union(totals.fnByClass.keys)
            for cls in classes.sorted() {
                print(
                    "[detect-class] class=\(cls) "
                        + "tp=\(totals.tpByClass[cls] ?? 0) "
                        + "fp=\(totals.fpByClass[cls] ?? 0) "
                        + "fn=\(totals.fnByClass[cls] ?? 0)",
                )
            }
            for bucket in totals.originErrBuckets.keys.sorted() {
                print("[origin-err] sp=\(Double(bucket) / 4) n=\(totals.originErrBuckets[bucket] ?? 0)")
            }
        }

        /// `pitchPcts`/`durPcts` are empty whenever `scored == 0` — every
        /// render on this sweep was seam-only (the whole degraded set) or
        /// there were none at all. `pitchP50=0.0000` over zero renders
        /// reads as a real (terrible) score rather than as "nothing was
        /// scored", so those fields print `n/a` instead, mirroring the
        /// score-eval harness's own `pctStr` convention.
        static func printScoreSummary(
            renders: Int, scored: Int, seamOnly: Int, failed: Int,
            pitchPcts: [Double], durPcts: [Double],
        ) {
            func fmt(_ values: [Double], _ stat: ([Double]) -> Double) -> String {
                values.isEmpty ? "n/a" : String(format: "%.4f", stat(values))
            }
            func mean(_ values: [Double]) -> Double {
                values.reduce(0, +) / Double(values.count)
            }
            print(
                "[detect][SUMMARY] renders=\(renders) scored=\(scored) "
                    + "seamOnly=\(seamOnly) failed=\(failed) "
                    + "pitchP50=\(fmt(pitchPcts) { OMRDetectorMetrics.percentile($0, 0.5) }) "
                    + "pitchMean=\(fmt(pitchPcts, mean)) "
                    + "durP50=\(fmt(durPcts) { OMRDetectorMetrics.percentile($0, 0.5) }) "
                    + "durMean=\(fmt(durPcts, mean))",
            )
        }
    }

    /// Ungated wiring test for `OMRDetectorEvalSweep.sweep`
    /// (`OMRHarnessFixture`'s bare 5-line staff carries no glyphs and no
    /// image file, so it cannot exercise a detector — this builds its own
    /// minimal render directories instead, following
    /// `OMRPrepExportHarnessTests`'s `PrepFixture` precedent). Proves the
    /// "one bad render is counted and does not stop the sweep"
    /// requirement without needing `OMR_DATA_ROOT` or `OMR_MODEL_ROOT`.
    @MainActor
    struct OMRDetectorEvalWiringTests {
        /// Stands in for a trained model: returns exactly what the label
        /// oracle would, restricted to the detector vocabulary and
        /// reframed into the front-end's own frame — the same pattern as
        /// `OMRHybridFrontEndTests.LabelReplayDetector`.
        struct LabelReplayDetector: OMRGlyphDetecting {
            func glyphs(
                page: OMRPageLabels, analysis: RasterPageAnalysis,
            ) throws -> [ClassifiedGlyph] {
                let oracle = try OMROracleFrontEnd.replay(pages: [page])
                let vocabulary = OMRHybridFrontEnd.detectorVocabularyGlyphs(oracle.walked.glyphs)
                return OMRHybridFrontEnd.reframe(vocabulary, page: page, transform: analysis.transform)
            }
        }

        static func stagePage(glyphs: [OMRPageLabels.Glyph]) throws -> (page: OMRPageLabels, score: Score) {
            let bitmap = RasterTestBitmaps.staff(
                widthPx: 900, heightPx: 500, dpi: 300, topY: 200, spacingPx: 16,
            )
            let analysis = RasterPage.analyze(bitmap, pageIndex: 0)
            let size = analysis.pageSizePt
            let page = OMRPageLabels(
                schema: 1,
                page: .init(index: 0, widthPt: size.width, heightPt: size.height),
                image: .init(
                    file: "page_0.png", dpi: 300,
                    labelTransform: [1, 0, 0, 0, 1, 0, 0, 0, 1], sourceSizePx: nil,
                ),
                glyphs: glyphs, paths: staffLinePaths, beams: [], curves: [], texts: [],
                census: .init(glyphsByClass: [:], texts: 0),
            )
            let replay = try OMROracleFrontEnd.replay(pages: [page])
            let score = try PDFImporter.buildScore(
                pageCount: replay.pageCount, walked: replay.walked, pageSizes: replay.pageSizes,
                documentAttributes: nil, options: PDFImportOptions(),
            )
            return (page, score)
        }

        /// render.json + score.pdf marker + labels + source.mscx + a
        /// real raster PNG — the well-formed case `.detectorGlyphs`
        /// succeeds on.
        static func stageGoodRender(at dir: String) throws {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let (page, score) = try stagePage(glyphs: [noteheadGlyph])
            let bitmap = RasterTestBitmaps.staff(
                widthPx: 900, heightPx: 500, dpi: 300, topY: 200, spacingPx: 16,
            )
            try OMRPrepPNG.write(bitmap, to: URL(fileURLWithPath: "\(dir)/page_0.png"))
            try stageCommonFiles(dir: dir, page: page, score: score)
        }

        /// render.json + labels + source.mscx, NO `page_0.png` — the
        /// "raster analysis unavailable" case `.detectorGlyphs` must
        /// throw on (`OMRHybridFrontEnd.compose`'s deliberate guard).
        /// Otherwise identical to `stageGoodRender` (same glyph, same
        /// derived score) so the only difference under test is the
        /// missing image, not an incidentally-empty page.
        static func stageBrokenRender(at dir: String) throws {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let (page, score) = try stagePage(glyphs: [noteheadGlyph])
            try stageCommonFiles(dir: dir, page: page, score: score)
        }

        /// `frozen.json` + labels + a real raster PNG, NO `source.mscx`
        /// — the shape `freeze` actually produces for the degraded eval
        /// set (marker name deliberately differs from `render.json` so a
        /// second `freeze` cannot re-degrade its own output, and the
        /// source is deliberately not copied). `.detectorGlyphs` must
        /// still run the seam pass over this directory and must NOT
        /// throw for the missing source — that is `seamOnly`, not
        /// `failed`.
        static func stageFrozenRender(at dir: String) throws {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let (page, _) = try stagePage(glyphs: [noteheadGlyph])
            let bitmap = RasterTestBitmaps.staff(
                widthPx: 900, heightPx: 500, dpi: 300, topY: 200, spacingPx: 16,
            )
            try OMRPrepPNG.write(bitmap, to: URL(fileURLWithPath: "\(dir)/page_0.png"))
            let markerJSON = try JSONSerialization.data(
                withJSONObject: ["render_id": (dir as NSString).lastPathComponent],
            )
            try markerJSON.write(to: URL(fileURLWithPath: "\(dir)/frozen.json"))
            try OMRLabelSchema.encodeCanonical(page)
                .write(to: URL(fileURLWithPath: "\(dir)/page_0.labels.json"))
            // Deliberately no source.mscx — `freeze` never copies it.
        }

        private static var noteheadGlyph: OMRPageLabels.Glyph {
            OMRPageLabels.Glyph(
                className: "noteheadBlack", bboxPt: nil,
                originPt: [200, 60], advancePt: 6, renderedSizePt: 5, fontSizePt: 0,
            )
        }

        /// A real 5-line staff (8pt spacing) straddling the notehead's y
        /// — `buildScore` needs a detectable staff, unlike
        /// `OMRHybridFrontEndTests`' fixtures, which never reach
        /// `buildScore` directly from a hand-built `OMRPageLabels`.
        private static var staffLinePaths: [OMRPageLabels.Path] {
            (0 ..< 5).map { i in
                let y = 40.0 + Double(i) * 8.0
                return OMRPageLabels.Path(kind: "horizontal", rectPt: [20, y, 380, y], lineWidthPt: 0.6)
            }
        }

        private static func stageCommonFiles(dir: String, page: OMRPageLabels, score: Score) throws {
            let renderJSON = try JSONSerialization.data(
                withJSONObject: ["pdf": "score.pdf", "dpi": 300],
            )
            try renderJSON.write(to: URL(fileURLWithPath: "\(dir)/render.json"))
            try OMRLabelSchema.encodeCanonical(page)
                .write(to: URL(fileURLWithPath: "\(dir)/page_0.labels.json"))
            try MSCXEncoder.encode(score).write(to: URL(fileURLWithPath: "\(dir)/source.mscx"))
        }

        /// "aaa_broken" sorts before "bbb_good" so the walk hits the
        /// failure first — proving a failed render is counted AND does
        /// not stop later renders from being processed and counted,
        /// mirroring `OMRPrepExportWiringTests.aFailedPageIsCountedAndDoesNotStopTheWalk`.
        @Test func aFailedRenderIsCountedAndDoesNotStopTheSweep() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("omr-detect-eval-wiring-\(UUID().uuidString)").path
            defer { try? FileManager.default.removeItem(atPath: root) }
            try Self.stageBrokenRender(at: "\(root)/aaa_broken")
            try Self.stageGoodRender(at: "\(root)/bbb_good")

            let result = try OMRDetectorEvalSweep.sweep(
                root: root, detector: LabelReplayDetector(), matchSp: 0.5,
            )
            #expect(result.renders == 2)
            #expect(result.totals.failed == 1)
            #expect(result.totals.pages == 1)
            #expect(result.totals.scored == 1)
            #expect(result.totals.seamOnly == 0)
        }

        /// The exact regression the coordinator reported: pointed at a
        /// directory tree that ONLY contains frozen (degraded) renders, a
        /// walk over `renderDirectories` sees nothing at all —
        /// `renders`/`pages` read 0, indistinguishable from a total
        /// detector failure. `renderOrFrozenDirectories` must find it,
        /// the seam pass must run and count `pages`/tp/fp/fn normally,
        /// and the outcome must land in `seamOnly`, never `failed` —
        /// `source.mscx` being absent here is expected, not an error.
        ///
        /// Verified by deletion: with `OMRDetectorEvalSweep.sweep`
        /// temporarily reverted to `renderDirectories`, this test failed
        /// with `renders == 0` and `pages == 0` (see the fix report).
        @Test func aFrozenRenderContributesSeamMetricsAndCountsAsSeamOnly() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("omr-detect-eval-frozen-\(UUID().uuidString)").path
            defer { try? FileManager.default.removeItem(atPath: root) }
            try Self.stageFrozenRender(at: "\(root)/frozen_0001")

            let result = try OMRDetectorEvalSweep.sweep(
                root: root, detector: LabelReplayDetector(), matchSp: 0.5,
            )
            #expect(result.renders == 1)
            #expect(result.totals.pages == 1)
            #expect(result.totals.seamOnly == 1)
            #expect(result.totals.scored == 0)
            #expect(result.totals.failed == 0)
        }
    }
#endif
