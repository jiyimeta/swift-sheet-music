#if !os(Android) && !os(WASI)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    struct OMRSeamMetricsUnitTests {
        static func glyph(
            _ cls: String, x: Double, y: Double, w: Double = 6, h: Double = 5,
        ) -> OMRPageLabels.Glyph {
            OMRPageLabels.Glyph(
                className: cls, bboxPt: [x, y, x + w, y + h],
                originPt: [x, y + h / 2], advancePt: w,
                renderedSizePt: h, fontSizePt: 0,
            )
        }

        @Test func iouOfIdenticalBoxesIsOne() {
            #expect(OMRSeamMetrics.iou([0, 0, 10, 10], [0, 0, 10, 10]) == 1.0)
            #expect(OMRSeamMetrics.iou([0, 0, 10, 10], [20, 20, 30, 30]) == 0.0)
            let half = OMRSeamMetrics.iou([0, 0, 10, 10], [0, 0, 10, 5])
            #expect(abs(half - 0.5) < 1e-9)
        }

        @Test func perfectPredictionsScorePerfectPRAndZeroErrors() {
            let truth = [
                Self.glyph("noteheadBlack", x: 100, y: 400),
                Self.glyph("noteheadBlack", x: 120, y: 404),
                Self.glyph("clefG", x: 55, y: 400, w: 10, h: 30),
            ]
            let m = OMRSeamMetrics.matchGlyphs(predicted: truth, truth: truth, staffSpacingPt: 8)
            #expect(m["noteheadBlack"]?.tp == 2)
            #expect(m["noteheadBlack"]?.fp == 0)
            #expect(m["noteheadBlack"]?.fn == 0)
            #expect(m["clefG"]?.tp == 1)
            #expect(m["noteheadBlack"]?.originErrPt.allSatisfy { $0 == 0 } == true)
        }

        @Test func missAndFalsePositiveAreCounted() {
            let truth = [Self.glyph("noteheadBlack", x: 100, y: 400)]
            let predicted = [Self.glyph("noteheadBlack", x: 300, y: 500)]
            let m = OMRSeamMetrics.matchGlyphs(predicted: predicted, truth: truth, staffSpacingPt: 8)
            #expect(m["noteheadBlack"]?.tp == 0)
            #expect(m["noteheadBlack"]?.fp == 1)
            #expect(m["noteheadBlack"]?.fn == 1)
        }

        @Test func tinyInkClassMatchesByCenterDistanceNotIoU() {
            // 1×1pt dot boxes offset by 0.8pt: IoU ≈ 0.01 (would fail 0.5)
            // but center distance 1.13pt < 0.5 × spacing 8 = 4 → match.
            let truth = [Self.glyph("augmentationDot", x: 100, y: 400, w: 1, h: 1)]
            let predicted = [Self.glyph("augmentationDot", x: 100.8, y: 400.8, w: 1, h: 1)]
            let m = OMRSeamMetrics.matchGlyphs(predicted: predicted, truth: truth, staffSpacingPt: 8)
            #expect(m["augmentationDot"]?.tp == 1)
        }

        @Test func nilBboxOnNormalClassNeverMatchesAndIsCountedNotCrashed() {
            var t = Self.glyph("noteheadBlack", x: 100, y: 400)
            t.bboxPt = nil
            var p = Self.glyph("noteheadBlack", x: 100, y: 400)
            p.bboxPt = nil
            let m = OMRSeamMetrics.matchGlyphs(predicted: [p], truth: [t], staffSpacingPt: 8)
            #expect(m["noteheadBlack"]?.tp == 0)
            #expect(m["noteheadBlack"]?.fp == 1)
            #expect(m["noteheadBlack"]?.fn == 1)
        }

        @Test func staffSpacingComesFromDetectedStaffLines() {
            var content = WalkedContent(glyphs: [], texts: [], paths: [], curves: [])
            for i in 0 ..< 5 {
                content.paths.append(PathSegment(
                    kind: .horizontal,
                    rect: CGRect(x: 50, y: 400 + CGFloat(i) * 8, width: 400, height: 0),
                    lineWidth: 0.6, pageIndex: 0, quad: nil,
                ))
            }
            let labels = OMRLabelSchema.pageLabels(
                walked: content, pageIndex: 0,
                pageSize: CGSize(width: 595, height: 842), dpi: 300,
                imageFile: "page_0.png", inkBBox: { _ in nil },
            )
            #expect(abs(OMRSeamMetrics.staffSpacing(page: labels) - 8.0) < 0.5)
        }

        static func beam(
            x0: Double, x1: Double, topY: Double, thickness: Double, slope: Double = 0,
        ) -> OMRPageLabels.Beam {
            OMRPageLabels.Beam(
                rectPt: [x0, topY - thickness, x1, topY], lineWidthPt: 0,
                x0: x0, x1: x1,
                topSlope: slope, topIntercept: topY - slope * x0,
                botSlope: slope, botIntercept: topY - thickness - slope * x0,
            )
        }

        @Test func beamEdgeErrorIsZeroOnIdenticalBeams() {
            let beam = Self.beam(x0: 100, x1: 160, topY: 440.5, thickness: 2, slope: 0.05)
            let r = OMRSeamMetrics.beamEdgeError(predicted: [beam], truth: [beam])
            #expect(!r.errs.isEmpty)
            #expect(r.errs.allSatisfy { $0 == 0 })
            #expect(r.unmatchedTruth == 0)
        }

        @Test func emptyPredictionsAreAMissNotAPerfectScore() {
            let truth = [Self.beam(x0: 100, x1: 160, topY: 440, thickness: 2)]
            let r = OMRSeamMetrics.beamEdgeError(predicted: [], truth: truth)
            #expect(r.errs.isEmpty)
            #expect(r.unmatchedTruth == 1)

            let pr = OMRSeamMetrics.beamPR(predicted: [], truth: truth, staffSpacingPt: 8)
            #expect(pr.tp == 0)
            #expect(pr.fn == 1)
            #expect(pr.fp == 0)
        }

        @Test func oneFusedBeamCannotSatisfyTwoTruthBeams() {
            // Two stacked beams 3pt apart; a single fused slab is predicted.
            let truth = [
                Self.beam(x0: 100, x1: 160, topY: 440, thickness: 2),
                Self.beam(x0: 100, x1: 160, topY: 437, thickness: 2),
            ]
            let fused = [Self.beam(x0: 100, x1: 160, topY: 440, thickness: 5)]
            let pr = OMRSeamMetrics.beamPR(predicted: fused, truth: truth, staffSpacingPt: 8)
            #expect(pr.tp == 1)
            #expect(pr.fn == 1)
            #expect(pr.fp == 0)

            let r = OMRSeamMetrics.beamEdgeError(predicted: fused, truth: truth)
            #expect(r.unmatchedTruth == 1)
        }

        @Test func beamPRCountsAnExtraPredictionAsAFalsePositive() {
            let truth = [Self.beam(x0: 100, x1: 160, topY: 440, thickness: 2)]
            let predicted = truth + [Self.beam(x0: 300, x1: 360, topY: 500, thickness: 2)]
            let pr = OMRSeamMetrics.beamPR(predicted: predicted, truth: truth, staffSpacingPt: 8)
            #expect(pr.tp == 1)
            #expect(pr.fp == 1)
            #expect(pr.fn == 0)
        }

        /// The exact blind spot `coverage` was added for: a beam detected
        /// at the right height but covering a third of its span is scored
        /// a clean true positive by the vertical-only match criterion.
        /// The tp/fp/fn half of this test is the DEFECT, asserted so it
        /// cannot be mistaken for a metric that catches truncation; the
        /// coverage half is what makes the defect visible.
        @Test func aTruncatedBeamStillScoresAsATruePositiveButLowCoverage() {
            let truth = [Self.beam(x0: 100, x1: 160, topY: 440, thickness: 2)]
            let truncated = [Self.beam(x0: 100, x1: 120, topY: 440, thickness: 2)]
            let pr = OMRSeamMetrics.beamPR(
                predicted: truncated, truth: truth, staffSpacingPt: 8,
            )
            #expect(pr.tp == 1)
            #expect(pr.fp == 0)
            #expect(pr.fn == 0)
            #expect(pr.coverage.count == 1)
            #expect(abs((pr.coverage.first ?? 0) - 1.0 / 3) < 1e-9)
        }

        /// …and a beam that covers its truth exactly reports 1.0, or the
        /// test above would pass for a coverage that always read low.
        @Test func anExactBeamReportsFullCoverage() {
            let truth = [Self.beam(x0: 100, x1: 160, topY: 440, thickness: 2)]
            let pr = OMRSeamMetrics.beamPR(
                predicted: truth, truth: truth, staffSpacingPt: 8,
            )
            #expect(pr.coverage == [1.0])
        }

        /// A prediction that OVERHANGS its truth is fully covering, not
        /// more than fully: the ratio is clamped, so an over-long beam
        /// cannot inflate the percentiles past 1.
        @Test func anOverhangingBeamIsClampedToFullCoverage() {
            let truth = [Self.beam(x0: 100, x1: 160, topY: 440, thickness: 2)]
            let long = [Self.beam(x0: 60, x1: 200, topY: 440, thickness: 2)]
            let pr = OMRSeamMetrics.beamPR(
                predicted: long, truth: truth, staffSpacingPt: 8,
            )
            #expect(pr.coverage == [1.0])
        }

        @Test func staffLineRecallAndBarlinePROnIdenticalPaths() {
            let lines = (0 ..< 5).map {
                OMRPageLabels.Path(
                    kind: "horizontal",
                    rectPt: [50, 400 + Double($0) * 8, 450, 400 + Double($0) * 8],
                    lineWidthPt: 0.6,
                )
            }
            let bar = OMRPageLabels.Path(
                kind: "vertical", rectPt: [450, 400, 450, 432], lineWidthPt: 1.2,
            )
            let paths = lines + [bar]
            let recall = OMRSeamMetrics.staffLineRecall(
                predicted: paths, truth: paths, staffSpacingPt: 8,
            )
            #expect(recall.matched == 5)
            #expect(recall.total == 5)
            #expect(recall.endpointErrPt.allSatisfy { $0 == 0 })

            let pr = OMRSeamMetrics.barlinePR(predicted: paths, truth: paths, staffSpacingPt: 8)
            #expect(pr.tp == 1)
            #expect(pr.fp == 0)
            #expect(pr.fn == 0)
        }

        /// The labels carry one staff line as several co-linear segments
        /// (1 to 10, measured), while a raster front-end emits one merged
        /// segment per line. Matching those two representations
        /// one-to-one scores a perfect detector at roughly one over the
        /// fragment count — the first raster sweep read 0.176 recall for
        /// exactly this and none of it was detector error.
        @Test func collinearFragmentsMergeIntoOneLine() {
            let fragments = [
                OMRPageLabels.Path(
                    kind: "horizontal", rectPt: [0, 100, 60, 100], lineWidthPt: 1,
                ),
                OMRPageLabels.Path(
                    kind: "horizontal", rectPt: [60, 100.4, 120, 100.4], lineWidthPt: 1,
                ),
                OMRPageLabels.Path(
                    kind: "horizontal", rectPt: [0, 108, 120, 108], lineWidthPt: 1,
                ),
                OMRPageLabels.Path(
                    kind: "vertical", rectPt: [0, 90, 0, 130], lineWidthPt: 1,
                ),
            ]
            let merged = OMRSeamMetrics.mergedHorizontals(fragments)
            let lines = merged.filter { $0.kind == "horizontal" }
            #expect(lines.count == 2)
            #expect(lines[0].rectPt[0] == 0)
            #expect(lines[0].rectPt[2] == 120)
            // Verticals pass through untouched — the merge is about the
            // staff-line representation, not about paths in general.
            #expect(merged.contains { $0.kind == "vertical" })
        }

        /// Lines further apart than the tolerance must stay separate, or
        /// the merge would fuse the five lines of one staff into one.
        @Test func linesFurtherApartThanTheToleranceStaySeparate() {
            let lines = (0 ..< 5).map {
                OMRPageLabels.Path(
                    kind: "horizontal",
                    rectPt: [0, 100 + Double($0) * 8, 400, 100 + Double($0) * 8],
                    lineWidthPt: 1,
                )
            }
            #expect(OMRSeamMetrics.mergedHorizontals(lines).count == 5)
        }

        @Test func curveRecallOnIdenticalCurves() {
            let curve = OMRPageLabels.Curve(
                bboxPt: [100, 400, 140, 410], leftPt: [100, 400], rightPt: [140, 400],
            )
            let recall = OMRSeamMetrics.curveRecall(
                predicted: [curve], truth: [curve], staffSpacingPt: 8,
            )
            #expect(recall.matched == 1)
            #expect(recall.total == 1)
            #expect(recall.endpointErrPt.allSatisfy { $0 == 0 })
        }
    }

    /// Seam-level harness (spec §8.1). In P3-0 the front-end IS the
    /// oracle, so this is a self-check: every class must report P=R=1.
    /// No-op unless OMR_SEAM_EVAL=1. Prints, never asserts.
    @Suite(.enabled(if: ProcessInfo.processInfo.environment["OMR_SEAM_EVAL"] == "1"))
    struct OMRSeamEvalHarness {
        @Test func selfCheckOracleAgainstLabels() throws {
            guard let root = ProcessInfo.processInfo.environment["OMR_DATA_ROOT"] else {
                Issue.record("OMR_SEAM_EVAL=1 but OMR_DATA_ROOT is unset")
                return
            }
            let renderDirs = try OMRHarnessDirectoryWalk.renderDirectories(root: root)
            var aggregate: [String: OMRSeamMetrics.ClassCounts] = [:]
            for dir in renderDirs {
                // One pool per render — see the note in
                // `OMRLabelExportHarness`.
                try autoreleasepool {
                    try evaluate(dir: dir, aggregate: &aggregate)
                }
            }
            for cls in aggregate.keys.sorted() {
                guard let c = aggregate[cls] else { continue }
                let precision = c.tp + c.fp > 0 ? Double(c.tp) / Double(c.tp + c.fp) : 1
                let recall = c.tp + c.fn > 0 ? Double(c.tp) / Double(c.tp + c.fn) : 1
                print(
                    "[seam][SUMMARY] class=\(cls) tp=\(c.tp) fp=\(c.fp) fn=\(c.fn) "
                        + "P=\(String(format: "%.4f", precision)) "
                        + "R=\(String(format: "%.4f", recall))",
                )
            }
        }

        /// One render directory: every `.labels.json` page is self-matched
        /// (predicted == truth == the same labels — the oracle self-check),
        /// per-page geometry rows printed, per-class counts folded into
        /// `aggregate`. Split out of the @Test body to stay under the
        /// 60-line function-body cap.
        ///
        /// Not `private`: Task 9's `OMRHarnessWiringTests` drives this
        /// directly against a synthetic fixture (including a directory
        /// with no `.labels.json`, which must no-op rather than throw).
        ///
        /// Returns the number of `.labels.json` pages processed (Task 9
        /// review, finding 3). `aggregate` alone cannot distinguish
        /// "genuinely processed, zero glyphs" from "silently skipped" —
        /// the fixture's glyph-less well-formed directory yields an empty
        /// `aggregate` in BOTH cases, so a bug in the traversal that
        /// always found zero label files would pass an `aggregate`-only
        /// assertion for either directory. `@discardableResult` because
        /// the harness's own `@Test` loop below doesn't need the count.
        @discardableResult
        func evaluate(
            dir: String, aggregate: inout [String: OMRSeamMetrics.ClassCounts],
        ) throws -> Int {
            let labelPaths = try OMRHarnessDirectoryWalk.labelFiles(in: dir)
            for name in labelPaths {
                let page = try OMRLabelSchema.decode(
                    Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(name)")),
                )
                let spacing = OMRSeamMetrics.staffSpacing(page: page)
                let m = OMRSeamMetrics.matchGlyphs(
                    predicted: page.glyphs, truth: page.glyphs,
                    staffSpacingPt: spacing,
                )
                for cls in m.keys.sorted() {
                    guard let counts = m[cls] else { continue }
                    var agg = aggregate[cls] ?? OMRSeamMetrics.ClassCounts()
                    agg.tp += counts.tp
                    agg.fp += counts.fp
                    agg.fn += counts.fn
                    aggregate[cls] = agg
                }
                let lines = OMRSeamMetrics.staffLineRecall(
                    predicted: page.paths, truth: page.paths, staffSpacingPt: spacing,
                )
                let bars = OMRSeamMetrics.barlinePR(
                    predicted: page.paths, truth: page.paths, staffSpacingPt: spacing,
                )
                let beams = OMRSeamMetrics.beamEdgeError(predicted: page.beams, truth: page.beams)
                let beamPR = OMRSeamMetrics.beamPR(
                    predicted: page.beams, truth: page.beams, staffSpacingPt: spacing,
                )
                let curves = OMRSeamMetrics.curveRecall(
                    predicted: page.curves, truth: page.curves, staffSpacingPt: spacing,
                )
                print(
                    "[\((dir as NSString).lastPathComponent)/\(name)][page] "
                        + "staffSpacing=\(String(format: "%.3f", spacing)) "
                        + "staffLines=\(lines.matched)/\(lines.total) "
                        + "barlines tp=\(bars.tp) fp=\(bars.fp) fn=\(bars.fn) "
                        + "beamEdgeMax=\(String(format: "%.3f", beams.errs.max() ?? 0)) "
                        + "beamPR tp=\(beamPR.tp) fp=\(beamPR.fp) fn=\(beamPR.fn) "
                        + "beamUnmatched=\(beams.unmatchedTruth) "
                        + "curves=\(curves.matched)/\(curves.total) "
                        + "texts=\(page.census.texts)",
                )
            }
            return labelPaths.count
        }
    }
#endif
