#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF

    /// Glyphs from the labels — a perfect detector, restricted to the
    /// frozen detector vocabulary — plus paths from the REAL raster
    /// pipeline, composed into one `WalkedContent` for `buildScore`.
    ///
    /// This is what isolates P3a/P3b's contribution. The denominator is
    /// the already-measured oracle-replay back-end ceiling (gate P0-G3),
    /// so the reported delta is this stage's cost and nothing else's.
    enum OMRHybridFrontEnd {
        /// Which primitives the raster front-end is allowed to contribute.
        ///
        /// The lobotomy modes exist so the harness can be shown to be
        /// capable of failing: dropping one primitive must crater one
        /// specific metric, and `nullFrontEnd` establishes the floor the
        /// real numbers have to sit far above. A harness whose floor is
        /// near its ceiling is measuring nothing.
        /// The `truth*` modes are the BISECT, not an anti-vacuity check.
        /// Each hands one primitive back to the oracle and leaves the rest
        /// raster, so the duration a mode recovers is that primitive's
        /// share of the loss — measured rather than argued. Half the
        /// eighths on this dataset arrive as quarters, which is a report
        /// of lost beam membership, and membership needs a beam AND the
        /// stem whose x it must span: `truthBeams` and `truthVerticals`
        /// separate those two without touching the front-end.
        enum Mode: String {
            case full
            case noStaffLines
            case noVerticals
            case noBeams
            case nullFrontEnd
            case truthStaffLines
            case truthVerticals
            case truthBeams
            /// Glyphs come from a REAL detector (`OMRGlyphDetecting`)
            /// instead of the label oracle; paths are still the raster
            /// front-end's own classical CV, unchanged from `.full`. This
            /// is the mode that turns the hybrid's numbers from "P3a/P3b's
            /// contribution against a known ceiling" into an end-to-end
            /// measurement. `nullFrontEnd` remains the floor for PATHS (no
            /// front-end at all); for GLYPHS under this mode, the floor is
            /// the untrained / random-checkpoint model (gate P3d-G1) —
            /// there is no separate lobotomy mode for glyphs because the
            /// detector itself, run with no training, already supplies one.
            case detectorGlyphs

            /// The path kind this mode takes from the oracle instead of
            /// the raster front-end.
            var substituted: PathSegment.Kind? {
                switch self {
                case .truthStaffLines: .horizontal
                case .truthVerticals: .vertical
                case .truthBeams: .beam
                default: nil
                }
            }
        }

        static func filter(_ paths: [PathSegment], mode: Mode) -> [PathSegment] {
            if let substituted = mode.substituted {
                return paths.filter { $0.kind != substituted }
            }
            switch mode {
            case .full: return paths
            case .noStaffLines: return paths.filter { $0.kind != .horizontal }
            case .noVerticals: return paths.filter { $0.kind != .vertical }
            case .noBeams: return paths.filter { $0.kind != .beam }
            case .nullFrontEnd: return []
            default: return paths
            }
        }

        /// Label glyphs a detector could actually emit.
        ///
        /// `unknown*` classes really occur in these labels
        /// (`unknownE500`, `unknownECA5` in the `extz_` renders) and a
        /// detector trained on a frozen vocabulary has no such class.
        /// `stem` and `staff5Lines` are excluded by the parent design's
        /// §7.1 — stems are this stage's own classical CV, and
        /// `staff5Lines` is a vector-only rendering artifact whose
        /// survival here would let `appendGlyphDetectedStaves` paper over
        /// a raster staff-detection failure outright.
        ///
        /// `fontSize` is zeroed to match the raster contract: the
        /// `staff5Lines` code path is unreachable from a front-end that
        /// detects staff lines directly.
        static func detectorVocabularyGlyphs(
            _ glyphs: [ClassifiedGlyph],
        ) -> [ClassifiedGlyph] {
            glyphs.compactMap { glyph in
                let name = OMRLabelClassNames.className(for: glyph.semantic)
                guard !name.hasPrefix("unknown"),
                      !excludedClasses.contains(name) else { return nil }
                var out = glyph
                out.geometry.fontSize = 0
                return out
            }
        }

        static let excludedClasses: Set = ["stem", "staff5Lines"]

        /// EXPERIMENT, **MEASURED AND REJECTED**
        /// (`OMR_HYBRID_DROP_GLYPH_VERTICALS=1`): drop raster verticals
        /// whose ink sits inside a non-notehead glyph.
        ///
        /// The diagnosis it was built to test is sound. The seam assumes
        /// `paths` and `glyphs` are DISJOINT ink, which holds for a
        /// vector PDF — MuseScore draws barlines and stems as strokes and
        /// clefs as glyphs — and fails for a raster, which sees only ink.
        /// Measured on `cov_wholes`, the raster emits eleven extra
        /// verticals at x = 49…106, the clef / key / time region, some of
        /// them 30pt tall against a 25pt staff; one survives as a
        /// barline, the score gains one measure, and the measure-aligned
        /// pitch comparison then reads 0% on a render the oracle scores
        /// 100%.
        ///
        /// The REMEDY is what failed. Over 177 renders:
        ///
        ///                        pitch p50   pitch mean   dur p50   measures exact
        ///     unchanged          52          46.6         38        130
        ///     drop-in-glyph      48          45.5         33        113
        ///
        /// Every column moves the wrong way: the filter also removes real
        /// barlines, which at a system start sit right beside the clef it
        /// is trying to reject. Kept here, env-gated and unused, so the
        /// next reader does not spend another round rediscovering that a
        /// correct diagnosis does not make this remedy correct — and
        /// above all does NOT take it into `barlineCandidates`, where it
        /// would have been measured only after shipping.
        ///
        /// Glyph boxes are available here only because the hybrid feeds
        /// label glyphs; the front-end itself has none, which is why any
        /// real fix has to live downstream.
        static func dropVerticalsInsideGlyphs(
            _ paths: [PathSegment], glyphs: [ClassifiedGlyph], spacingPt: Double,
        ) -> [PathSegment] {
            guard spacingPt > 0 else { return paths }
            let blockers = glyphs.filter { !isNoteheadLike($0.semantic) }.map {
                (
                    x: Double($0.geometry.origin.x),
                    y: Double($0.geometry.origin.y),
                    w: Double($0.geometry.advance),
                    h: Double($0.geometry.renderedSize),
                )
            }
            guard !blockers.isEmpty else { return paths }
            return paths.filter { path in
                guard path.kind == .vertical else { return true }
                let x = Double(path.rect.midX)
                let y = Double(path.rect.midY)
                return !blockers.contains { block in
                    x >= block.x - 0.2 * spacingPt
                        && x <= block.x + block.w + 0.2 * spacingPt
                        && y >= block.y - block.h
                        && y <= block.y + block.h
                }
            }
        }

        private static func isNoteheadLike(_ semantic: SMuFLSemantic) -> Bool {
            OMRLabelClassNames.className(for: semantic).hasPrefix("notehead")
        }

        /// Bring label glyphs — which live in CLEAN page space — into the
        /// frame the raster front-end emitted its paths in.
        ///
        /// The composition, and why each step is there:
        ///
        ///     clean pt  --(y-flip on the CLEAN raster height)-->  clean px
        ///     clean px  --(image.label_transform)-->              source px
        ///     source px --(the front-end's own deskew + flip)-->  page pt
        ///
        /// On a clean raster every step is the identity, which is exactly
        /// why getting this wrong stays invisible until the first
        /// degraded sweep and then reads as "the detector is bad". The
        /// y-flip has to be anchored to `image.source_size_px` — the
        /// CLEAN raster's height — because the degraded image has been
        /// resampled and is a different size.
        ///
        /// Composed this way, whatever deskew error remains moves glyphs
        /// and paths TOGETHER, so the relative geometry the back-end
        /// actually reasons about stays consistent.
        static func reframe(
            _ glyphs: [ClassifiedGlyph], page: OMRPageLabels, transform: PageTransform,
        ) -> [ClassifiedGlyph] {
            guard let context = frameContext(page: page, transform: transform)
            else { return glyphs }
            return glyphs.map { glyph in
                var out = glyph
                out.geometry.origin = context(glyph.geometry.origin)
                return out
            }
        }

        /// The same composition, for label PATHS.
        ///
        /// The seam harness compares the front-end's paths against these,
        /// and needs them in the front-end's frame for the same reason
        /// the hybrid needs the glyphs there. Skipping it is not a small
        /// error: the first degraded seam sweep read 0.20 staff-line
        /// recall against 0.77 clean, while a Python probe of the same
        /// pipeline measured 0.91 — the whole gap was the unmapped
        /// truth, not the detector.
        static func reframe(
            _ paths: [OMRPageLabels.Path], page: OMRPageLabels, transform: PageTransform,
        ) -> [OMRPageLabels.Path] {
            guard let context = frameContext(page: page, transform: transform)
            else { return paths }
            return paths.map { path in
                var out = path
                let a = context(CGPoint(x: path.rectPt[0], y: path.rectPt[1]))
                let b = context(CGPoint(x: path.rectPt[2], y: path.rectPt[3]))
                out.rectPt = [
                    min(Double(a.x), Double(b.x)), min(Double(a.y), Double(b.y)),
                    max(Double(a.x), Double(b.x)), max(Double(a.y), Double(b.y)),
                ]
                return out
            }
        }

        /// The same composition, for label BEAMS: both edges are mapped
        /// at their two endpoints and refitted, since a rotation changes
        /// a line's slope as well as its position.
        static func reframe(
            _ beams: [OMRPageLabels.Beam], page: OMRPageLabels, transform: PageTransform,
        ) -> [OMRPageLabels.Beam] {
            guard let context = frameContext(page: page, transform: transform)
            else { return beams }
            return beams.map { beam in
                var out = beam
                let top = fit(
                    context,
                    x0: beam.x0,
                    x1: beam.x1,
                    slope: beam.topSlope,
                    intercept: beam.topIntercept,
                )
                let bottom = fit(
                    context,
                    x0: beam.x0,
                    x1: beam.x1,
                    slope: beam.botSlope,
                    intercept: beam.botIntercept,
                )
                out.x0 = top.x0
                out.x1 = top.x1
                out.topSlope = top.slope
                out.topIntercept = top.intercept
                out.botSlope = bottom.slope
                out.botIntercept = bottom.intercept
                return out
            }
        }

        /// The same composition, for the ORACLE's own `PathSegment`s —
        /// what the `truth*` bisect modes substitute for a raster
        /// primitive. A `.beam` carries its quad, so both fitted edges are
        /// re-fitted through the map exactly as the label-beam overload
        /// does; every other kind is a degenerate rect and maps as two
        /// corners.
        static func reframe(
            _ paths: [PathSegment], page: OMRPageLabels, transform: PageTransform,
        ) -> [PathSegment] {
            guard let context = frameContext(page: page, transform: transform)
            else { return paths }
            return paths.map { path in
                var out = path
                let a = context(CGPoint(x: path.rect.minX, y: path.rect.minY))
                let b = context(CGPoint(x: path.rect.maxX, y: path.rect.maxY))
                out.rect = CGRect(
                    x: min(a.x, b.x), y: min(a.y, b.y),
                    width: abs(b.x - a.x), height: abs(b.y - a.y),
                )
                if let q = path.quad {
                    let top = fit(
                        context, x0: Double(q.xRange.lowerBound),
                        x1: Double(q.xRange.upperBound),
                        slope: Double(q.topSlope), intercept: Double(q.topIntercept),
                    )
                    let bottom = fit(
                        context, x0: Double(q.xRange.lowerBound),
                        x1: Double(q.xRange.upperBound),
                        slope: Double(q.botSlope), intercept: Double(q.botIntercept),
                    )
                    out.quad = BeamQuad(
                        xRange: CGFloat(min(top.x0, top.x1))
                            ... CGFloat(max(top.x0, top.x1)),
                        topSlope: CGFloat(top.slope),
                        topIntercept: CGFloat(top.intercept),
                        botSlope: CGFloat(bottom.slope),
                        botIntercept: CGFloat(bottom.intercept),
                        pageIndex: q.pageIndex,
                    )
                }
                return out
            }
        }

        private static func fit(
            _ map: (CGPoint) -> CGPoint, x0: Double, x1: Double,
            slope: Double, intercept: Double,
        ) -> (x0: Double, x1: Double, slope: Double, intercept: Double) {
            let a = map(CGPoint(x: x0, y: slope * x0 + intercept))
            let b = map(CGPoint(x: x1, y: slope * x1 + intercept))
            let dx = Double(b.x - a.x)
            let m = abs(dx) < 1e-9 ? 0 : Double(b.y - a.y) / dx
            return (Double(a.x), Double(b.x), m, Double(a.y) - m * Double(a.x))
        }

        /// The clean-page-point → front-end-page-point map for this page.
        ///
        /// Non-private because the prep export needs exactly this
        /// composition and must not grow a second copy of it: on a clean
        /// raster every step is the identity, so a second copy stays
        /// invisible until the first degraded run.
        static func pointMap(
            page: OMRPageLabels, transform: PageTransform,
        ) -> (CGPoint) -> CGPoint {
            frameContext(page: page, transform: transform) ?? { $0 }
        }

        /// The clean-page-point → front-end-page-point map for this page,
        /// or nil when it is the identity.
        private static func frameContext(
            page: OMRPageLabels, transform: PageTransform,
        ) -> ((CGPoint) -> CGPoint)? {
            let h = page.image.labelTransform
            let identity = h == [1, 0, 0, 0, 1, 0, 0, 0, 1]
            guard !identity || transform.deskewDegrees != 0 else { return nil }
            let dpi = Double(page.image.dpi)
            let cleanHeightPx = Double(
                page.image.sourceSizePx?[1]
                    ?? Int((page.page.heightPt * dpi / 72.0).rounded()),
            )
            return { point in
                mapped(
                    point, h: h, dpi: dpi,
                    cleanHeightPx: cleanHeightPx, transform: transform,
                )
            }
        }

        private static func mapped(
            _ point: CGPoint, h: [Double], dpi: Double,
            cleanHeightPx: Double, transform: PageTransform,
        ) -> CGPoint {
            let cleanX = Double(point.x) * dpi / 72.0
            let cleanY = cleanHeightPx - Double(point.y) * dpi / 72.0
            let w = h[6] * cleanX + h[7] * cleanY + h[8]
            let denominator = w == 0 ? 1 : w
            let sourceX = (h[0] * cleanX + h[1] * cleanY + h[2]) / denominator
            let sourceY = (h[3] * cleanX + h[4] * cleanY + h[5]) / denominator
            return transform.pagePoint(fromSourcePixelX: sourceX, y: sourceY)
        }

        /// Displace every glyph origin by a fixed offset in staff spaces,
        /// deterministically per glyph index.
        ///
        /// The hybrid otherwise feeds PERFECT origins, while a real
        /// detector will feed noisy ones — and `barlineCandidates`'
        /// 2.0 / 0.6 staff-space windows, which decide whether a vertical
        /// is a stem or a barline, were calibrated against vector
        /// geometry rather than detector jitter. Running the sweep at a
        /// few sigmas turns that into a number: the detector's
        /// origin-error budget, obtained a stage early instead of as a
        /// surprise. Reported, never gated.
        ///
        /// Deterministic (a fixed function of the index, not a PRNG draw)
        /// so the run-twice gate still holds with jitter enabled.
        static func jitter(
            _ glyphs: [ClassifiedGlyph], sigmaInSpaces: Double, staffSpacingPt: Double,
        ) -> [ClassifiedGlyph] {
            guard sigmaInSpaces > 0, staffSpacingPt > 0 else { return glyphs }
            let amplitude = sigmaInSpaces * staffSpacingPt
            return glyphs.enumerated().map { index, glyph in
                var out = glyph
                let phase = Double(index)
                out.geometry.origin.x += CGFloat(sin(phase * 1.7) * amplitude)
                out.geometry.origin.y += CGFloat(cos(phase * 2.3) * amplitude)
                return out
            }
        }

        /// One render's pages → the `buildScore` input tuple.
        ///
        /// `pageSizes` comes from the FRONT-END's own frame (its deskewed
        /// pixels × 72/dpi), never from the label's clean page size. On a
        /// degraded page those differ, and mixing them shifts every path
        /// relative to every glyph — silently, because on a clean raster
        /// the two frames coincide.
        static func compose(
            pages: [OMRPageLabels], analyses: [Int: RasterPageAnalysis], mode: Mode,
            originJitterInSpaces: Double = 0, detector: (any OMRGlyphDetecting)? = nil,
        ) throws -> (walked: WalkedContent, pageSizes: [Int: CGSize], pageCount: Int) {
            let oracle = try OMROracleFrontEnd.replay(pages: pages)
            var walked = WalkedContent(glyphs: [], texts: [], paths: [], curves: [])
            var sizes: [Int: CGSize] = [:]
            for page in pages.sorted(by: { $0.page.index < $1.page.index }) {
                let index = page.page.index
                let vocabulary = detectorVocabularyGlyphs(
                    oracle.walked.glyphs.filter { $0.geometry.pageIndex == index },
                )
                walked.texts += oracle.walked.texts.filter { $0.pageIndex == index }
                guard let analysis = analyses[index] else {
                    walked.glyphs += vocabulary
                    sizes[index] = oracle.pageSizes[index] ?? .zero
                    continue
                }
                let pageGlyphs: [ClassifiedGlyph]
                switch mode {
                case .detectorGlyphs:
                    guard let detector else {
                        throw hybridError("detectorGlyphs needs a detector")
                    }
                    // No `reframe` and no `jitter`: the detector works on
                    // the front-end's OWN deskewed pixels, so its output is
                    // already in the frame the paths are in. Reframing it
                    // would apply the label transform a second time, and
                    // jittering it would be simulating noise on top of the
                    // detector's own (real) noise.
                    pageGlyphs = try detector.glyphs(page: page, analysis: analysis)
                default:
                    pageGlyphs = jitter(
                        reframe(vocabulary, page: page, transform: analysis.transform),
                        sigmaInSpaces: originJitterInSpaces,
                        staffSpacingPt: analysis.staffSpacingPt,
                    )
                }
                walked.glyphs += pageGlyphs
                var pagePaths = filter(analysis.paths, mode: mode)
                if let substituted = mode.substituted {
                    pagePaths += reframe(
                        oracle.walked.paths.filter {
                            $0.pageIndex == index && $0.kind == substituted
                        },
                        page: page, transform: analysis.transform,
                    )
                }
                if ProcessInfo.processInfo
                    .environment["OMR_HYBRID_DROP_GLYPH_VERTICALS"] == "1"
                {
                    pagePaths = dropVerticalsInsideGlyphs(
                        pagePaths, glyphs: vocabulary,
                        spacingPt: analysis.staffSpacingPt,
                    )
                }
                walked.paths += pagePaths
                sizes[index] = analysis.pageSizePt
            }
            return (walked, sizes, oracle.pageCount)
        }

        /// `.detectorGlyphs` asking for a detector it wasn't given must
        /// throw, not silently fall back to the label oracle — a silent
        /// fallback would report label-quality numbers under a detector
        /// heading.
        private static func hybridError(_ reason: String) -> Error {
            SheetMusicError.malformedScore(reason: "OMRHybridFrontEnd: \(reason)")
        }
    }
#endif
