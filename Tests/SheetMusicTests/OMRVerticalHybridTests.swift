#if !os(Android) && !os(WASI)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicPDF
    import Testing

    /// The decomposition is only worth reading if the MATCHING is
    /// granularity-tolerant. With centre matching, the labels' per-staff
    /// split of a system barline against the raster's single merged column
    /// scores as one miss plus several false positives — and then
    /// `dropVerticalFalsePositives` would delete real barlines while
    /// `addVerticalMisses` re-added them, with both modes reporting a
    /// component that does not exist. Every test here is aimed at that.
    struct OMRVerticalHybridTests {
        static let spacing = 10.0

        static func vertical(
            x: Double, y0: Double, y1: Double, fromRaster: Bool = true,
            width: Double = 0,
        ) -> PathSegment {
            PathSegment(
                kind: .vertical,
                rect: CGRect(x: x, y: y0, width: width, height: y1 - y0),
                lineWidth: 1, pageIndex: 0, quad: nil,
                detectedFromRaster: fromRaster,
            )
        }

        /// One merged detection over two per-staff truth segments: neither
        /// a false positive nor two misses.
        @Test func aMergedBarlineIsNeitherFalsePositiveNorMiss() {
            let detected = [Self.vertical(x: 100, y0: 100, y1: 200)]
            let truth = [
                Self.vertical(x: 100, y0: 100, y1: 145, fromRaster: false),
                Self.vertical(x: 100, y0: 155, y1: 200, fromRaster: false),
            ]
            let out = OMRVerticalHybrid.apply(
                .dropFalsePositives, detected: detected, truth: truth,
                spacing: Self.spacing,
            )
            #expect(out.stats.falsePositives == 0)
            #expect(out.stats.explained == 1)
            #expect(out.stats.truthsMissed == 0)
            #expect(out.kept.compactMap(\.self).count == 1)
        }

        /// …and snapping it must not shrink it onto ONE of the staves it
        /// spans. Policy: the union hull of the truths it covers.
        @Test func aMergedBarlineSnapsToTheUnionHull() {
            let detected = [Self.vertical(x: 100, y0: 102, y1: 197)]
            let truth = [
                Self.vertical(x: 100, y0: 100, y1: 145, fromRaster: false),
                Self.vertical(x: 100, y0: 155, y1: 200, fromRaster: false),
            ]
            let out = OMRVerticalHybrid.apply(
                .snapEndpoints, detected: detected, truth: truth, spacing: Self.spacing,
            )
            let snapped = try? #require(out.kept[0])
            #expect(snapped?.rect.minY == 100)
            #expect(snapped?.rect.maxY == 200)
            #expect(out.stats.snapMerged == 1)
            #expect(out.stats.snapSingle == 0)
        }

        /// The 1:1 case this mode exists for: the column is found, its two
        /// ends are off. Snapping takes the truth's extent and its centre
        /// x, and leaves the raster provenance flag alone — otherwise
        /// `snapEndpoints` would also be silently pricing `unflagVerticals`.
        @Test func aMatchedDetectionTakesItsTruthPartnersExtent() {
            let detected = [Self.vertical(x: 100.4, y0: 103, y1: 196)]
            let truth = [Self.vertical(x: 100, y0: 100, y1: 200, fromRaster: false)]
            let out = OMRVerticalHybrid.apply(
                .snapEndpoints, detected: detected, truth: truth, spacing: Self.spacing,
            )
            let snapped = try? #require(out.kept[0])
            #expect(snapped?.rect.minY == 100)
            #expect(snapped?.rect.maxY == 200)
            #expect(snapped?.rect.midX == 100)
            #expect(snapped?.detectedFromRaster == true)
            #expect(out.stats.snapSingle == 1)
        }

        @Test func aDetectionNoTruthExplainsIsDropped() {
            let detected = [
                Self.vertical(x: 100, y0: 100, y1: 200),
                Self.vertical(x: 300, y0: 40, y1: 52),
            ]
            let truth = [Self.vertical(x: 100, y0: 100, y1: 200, fromRaster: false)]
            let out = OMRVerticalHybrid.apply(
                .dropFalsePositives, detected: detected, truth: truth,
                spacing: Self.spacing,
            )
            #expect(out.stats.falsePositives == 1)
            #expect(out.kept.map { $0 != nil } == [true, false])
        }

        /// A rescued truth must arrive shaped like a DETECTION —
        /// `detectedFromRaster: true` — so it faces `isStem`'s head-to-end
        /// gate exactly as a detected vertical does. Given the oracle's
        /// own flag it would carry `unflagVerticals`' effect with it and
        /// the two components would no longer add up.
        @Test func aMissedTruthIsAddedAsARasterDetection() {
            let detected = [Self.vertical(x: 100, y0: 100, y1: 200)]
            let truth = [
                Self.vertical(x: 100, y0: 100, y1: 200, fromRaster: false),
                Self.vertical(x: 500, y0: 40, y1: 60, fromRaster: false, width: 1.2),
            ]
            let out = OMRVerticalHybrid.apply(
                .addMisses, detected: detected, truth: truth, spacing: Self.spacing,
            )
            #expect(out.stats.truthsMissed == 1)
            #expect(out.added.count == 1)
            #expect(out.added.first?.detectedFromRaster == true)
            #expect(out.added.first?.rect.midX == 500.6)
            #expect(out.added.first?.rect.height == 20)
            #expect(out.kept.compactMap(\.self).count == 1)
        }

        /// The one that MEASURED as a disaster before it was a test: an
        /// unmatched detection overlapping a truth must be left exactly
        /// as it is. Snapping it stretches junk to full stem length —
        /// durP50 82.0 -> 42.0 over the eval set — and prices the false
        /// positives inside the endpoint component.
        @Test func anUnmatchedDetectionIsNeverSnapped() {
            // 2sp of ink inside a 20sp truth's y-extent: far too little
            // of the TRUTH to cover it, while the truth covers all of IT
            // — which is the leniency that makes this dangerous.
            let detected = [Self.vertical(x: 100, y0: 100, y1: 120)]
            let truth = [Self.vertical(x: 100, y0: 60, y1: 260, fromRaster: false)]
            let out = OMRVerticalHybrid.apply(
                .snapEndpoints, detected: detected, truth: truth, spacing: Self.spacing,
            )
            // Explained, so the match gate lets it through — and the 4x
            // length guard is the second line of defence that keeps a
            // 2sp detection from becoming a 20sp one.
            #expect(out.stats.snapRejectedByLength == 1)
            #expect(out.stats.snapNone == 1)
            #expect(out.kept.first??.rect == detected[0].rect)

            let junk = [Self.vertical(x: 300, y0: 100, y1: 112)]
            let far = OMRVerticalHybrid.apply(
                .snapEndpoints, detected: junk, truth: truth, spacing: Self.spacing,
            )
            #expect(far.stats.snapNotMatched == 1)
            #expect(far.kept.first??.rect == junk[0].rect)
        }

        /// The other one that MEASURED as a disaster: two fragments of
        /// one stem both explained by the same truth. Snapping both makes
        /// two IDENTICAL full-length verticals at one x — competing stems
        /// where the detector merely had a broken column — and the mode
        /// scores 43.0 durP50 against `full`'s 82.0.
        @Test func fragmentsSharingOneTruthAreLeftAlone() {
            let detected = [
                Self.vertical(x: 100, y0: 100, y1: 130),
                Self.vertical(x: 100, y0: 140, y1: 180),
            ]
            let truth = [Self.vertical(x: 100, y0: 100, y1: 190, fromRaster: false)]
            let out = OMRVerticalHybrid.apply(
                .snapEndpoints, detected: detected, truth: truth, spacing: Self.spacing,
            )
            #expect(out.stats.snapShared == 2)
            #expect(out.stats.snapSingle == 0)
            #expect(out.kept.compactMap(\.self).map(\.rect) == detected.map(\.rect))
        }

        /// The page border is a 184sp truth vertical at x = 0. It must not
        /// EXPLAIN junk that happens to share its x…
        @Test func aPageBorderDoesNotExplainAFalsePositive() {
            let detected = [Self.vertical(x: 2, y0: 400, y1: 412)]
            let truth = [Self.vertical(x: 0, y0: 0, y1: 1800, fromRaster: false)]
            let out = OMRVerticalHybrid.apply(
                .dropFalsePositives, detected: detected, truth: truth,
                spacing: Self.spacing,
            )
            #expect(out.stats.falsePositives == 1)
            #expect(out.stats.fpExplainedOnlyByBorder == 1)
        }

        /// …and it must not be a SNAP target either, or one stem at the
        /// page's own left edge would become a page-tall vertical.
        @Test func aPageBorderIsNotASnapTarget() {
            let border = Self.vertical(x: 0, y0: 0, y1: 1800, fromRaster: false)
            // Nothing musical explains it, so the match gate stops it
            // first — the border is not standing in for a partner.
            let junk = [Self.vertical(x: 2, y0: 400, y1: 412)]
            let unmatched = OMRVerticalHybrid.apply(
                .snapEndpoints, detected: junk, truth: [border], spacing: Self.spacing,
            )
            #expect(unmatched.kept.first??.rect.maxY == 412)
            #expect(unmatched.stats.snapNotMatched == 1)

            // A real stem at the same x, WITH the border overlapping it:
            // the snap must take the stem's extent, not the hull of stem
            // and border.
            let stem = [Self.vertical(x: 2, y0: 402, y1: 438)]
            let out = OMRVerticalHybrid.apply(
                .snapEndpoints, detected: stem,
                truth: [border, Self.vertical(x: 2, y0: 400, y1: 440, fromRaster: false)],
                spacing: Self.spacing,
            )
            #expect(out.kept.first??.rect.minY == 400)
            #expect(out.kept.first??.rect.maxY == 440)
            #expect(out.stats.snapSingle == 1)
        }

        /// `unflagRaster` moves the flag and NOTHING else — it is the
        /// control that says how much of `truthVerticals`' win is the
        /// `isStem` gate being skipped rather than better geometry.
        @Test func unflaggingChangesTheFlagAndNothingElse() {
            let detected = [Self.vertical(x: 100, y0: 103, y1: 196)]
            let truth = [Self.vertical(x: 100, y0: 100, y1: 200, fromRaster: false)]
            let out = OMRVerticalHybrid.apply(
                .unflagRaster, detected: detected, truth: truth, spacing: Self.spacing,
            )
            #expect(out.kept.first??.detectedFromRaster == false)
            #expect(out.kept.first??.rect == detected[0].rect)
            #expect(out.added.isEmpty)
        }
    }
#endif
