#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicMSCX
    @testable import SheetMusicPDF
    import Testing

    struct OMRHybridFrontEndTests {
        static func glyph(_ semantic: SMuFLSemantic) -> ClassifiedGlyph {
            ClassifiedGlyph(
                geometry: GlyphGeometry(
                    origin: CGPoint(x: 10, y: 12), advance: 6,
                    renderedSize: 5, pageIndex: 0, fontSize: 17,
                ),
                semantic: semantic,
            )
        }

        /// The hybrid must not grant abilities the detector will not
        /// have. `unknown*` really occurs in these labels, and `stem` /
        /// `staff5Lines` are outside the frozen detector vocabulary --
        /// stems are this stage's own classical CV, and a surviving
        /// `staff5Lines` would let `appendGlyphDetectedStaves` mask a
        /// raster staff-detection failure outright.
        @Test func nonVocabularyGlyphsAreDropped() {
            let kept = OMRHybridFrontEnd.detectorVocabularyGlyphs([
                Self.glyph(.noteheadBlack),
                Self.glyph(.unknown(0xE500)),
                Self.glyph(.stem),
                Self.glyph(.staff5Lines),
            ])
            #expect(kept.map(\.semantic) == [.noteheadBlack])
        }

        /// The raster contract sets `fontSize` to 0 — it is vector-only,
        /// read solely by the `staff5Lines` path, which a front-end that
        /// detects staff lines directly can never reach.
        @Test func fontSizeIsZeroedToMatchTheRasterContract() {
            let kept = OMRHybridFrontEnd.detectorVocabularyGlyphs(
                [Self.glyph(.noteheadBlack)],
            )
            #expect(kept.allSatisfy { $0.geometry.fontSize == 0 })
        }

        static func page(labelTransform: [Double]) -> OMRPageLabels {
            OMRPageLabels(
                schema: 1,
                page: .init(index: 0, widthPt: 612, heightPt: 792),
                image: .init(
                    file: "page_0.png", dpi: 300, labelTransform: labelTransform,
                    sourceSizePx: [2550, 3300],
                ),
                glyphs: [], paths: [], beams: [], curves: [], texts: [],
                census: .init(glyphsByClass: [:], texts: 0),
            )
        }

        /// Rotation about the raster centre by `degrees`, as a row-major
        /// 3×3 in PIXEL space — the same forward map
        /// `RasterTestBitmaps.rotated` applies, which is what
        /// `degrade.py`'s rotate stage records in `label_transform`.
        static func rotationTransform(degrees: Double) -> [Double] {
            let t = degrees * .pi / 180
            let c = cos(t)
            let s = sin(t)
            let cx = (2550.0 - 1) / 2
            let cy = (3300.0 - 1) / 2
            return [
                c, -s, cx - c * cx + s * cy,
                s, c, cy - s * cx - c * cy,
                0, 0, 1,
            ]
        }

        /// With no degradation and no deskew, reframing must be exactly
        /// the identity — otherwise every clean measurement would be
        /// reading the reframe's own error rather than the detector's.
        @Test func reframingACleanPageIsTheIdentity() {
            let transform = PageTransform(
                dpi: 300, widthPx: 2550, heightPx: 3300, deskewDegrees: 0,
            )
            let glyphs = [Self.glyph(.noteheadBlack)]
            let out = OMRHybridFrontEnd.reframe(
                glyphs, page: Self.page(labelTransform: [1, 0, 0, 0, 1, 0, 0, 0, 1]),
                transform: transform,
            )
            #expect(out.first?.geometry.origin == glyphs.first?.geometry.origin)
        }

        /// The composition that makes a degraded measurement mean
        /// anything: a page rotated by the degradation chain and then
        /// deskewed by the front-end must put a label glyph back where it
        /// started. This is the ONE property that is identity-shaped on
        /// clean rasters and therefore untestable there.
        @Test func degradationFollowedByDeskewRoundTripsAGlyphOrigin() {
            let degrees = 1.6
            let transform = PageTransform(
                dpi: 300, widthPx: 2550, heightPx: 3300, deskewDegrees: degrees,
            )
            let glyphs = [Self.glyph(.noteheadBlack)]
            let out = OMRHybridFrontEnd.reframe(
                glyphs,
                page: Self.page(labelTransform: Self.rotationTransform(degrees: degrees)),
                transform: transform,
            )
            let before = try? #require(glyphs.first?.geometry.origin)
            let after = try? #require(out.first?.geometry.origin)
            #expect(abs((after?.x ?? 0) - (before?.x ?? 0)) < 0.01)
            #expect(abs((after?.y ?? 0) - (before?.y ?? 0)) < 0.01)
        }

        /// …and the same rotation WITHOUT the matching deskew must move
        /// it, or the test above would pass for a reframe that ignored
        /// its inputs entirely.
        @Test func degradationWithoutDeskewMovesTheGlyph() {
            let transform = PageTransform(
                dpi: 300, widthPx: 2550, heightPx: 3300, deskewDegrees: 0,
            )
            let glyphs = [Self.glyph(.noteheadBlack)]
            let out = OMRHybridFrontEnd.reframe(
                glyphs,
                page: Self.page(labelTransform: Self.rotationTransform(degrees: 1.6)),
                transform: transform,
            )
            let moved = abs(
                (out.first?.geometry.origin.y ?? 0)
                    - (glyphs.first?.geometry.origin.y ?? 0),
            )
            #expect(moved > 1)
        }

        /// A lobotomy mode that silently equalled `.full` would make the
        /// anti-vacuity check itself vacuous, so each one is checked to
        /// remove its own primitive and only its own.
        @Test func everyLobotomyModeRemovesItsOwnPrimitive() {
            let paths = [
                PathSegment(
                    kind: .horizontal,
                    rect: CGRect(x: 0, y: 100, width: 400, height: 0),
                    lineWidth: 0.6, pageIndex: 0, quad: nil,
                ),
                PathSegment(
                    kind: .vertical,
                    rect: CGRect(x: 400, y: 100, width: 0, height: 32),
                    lineWidth: 1.2, pageIndex: 0, quad: nil,
                ),
                PathSegment(
                    kind: .beam,
                    rect: CGRect(x: 100, y: 140, width: 60, height: 2),
                    lineWidth: 2, pageIndex: 0,
                    quad: BeamQuad(
                        xRange: 100 ... 160, topSlope: 0, topIntercept: 142,
                        botSlope: 0, botIntercept: 140, pageIndex: 0,
                    ),
                ),
            ]
            #expect(OMRHybridFrontEnd.filter(paths, mode: .full).count == 3)
            #expect(
                OMRHybridFrontEnd.filter(paths, mode: .noStaffLines)
                    .allSatisfy { $0.kind != .horizontal },
            )
            #expect(OMRHybridFrontEnd.filter(paths, mode: .noStaffLines).count == 2)
            #expect(OMRHybridFrontEnd.filter(paths, mode: .noVerticals).count == 2)
            #expect(OMRHybridFrontEnd.filter(paths, mode: .noBeams).count == 2)
            #expect(OMRHybridFrontEnd.filter(paths, mode: .nullFrontEnd).isEmpty)
        }
    }

    /// Score-level evaluation of the hybrid front-end against
    /// `source.mscx` (design spec §8.2). No-op unless
    /// `OMR_HYBRID_EVAL=1`. `OMR_HYBRID_MODE` selects the anti-vacuity
    /// variant (`full` | `noStaffLines` | `noVerticals` | `noBeams` |
    /// `nullFrontEnd`), default `full`. Prints, never asserts.
    ///
    /// READ `measuresA` / `measuresB` BEFORE ANY PERCENTAGE. This harness
    /// inherits the real-corpus metric blind spots by design:
    /// end-truncated parts keep percentages high, mid-score part loss
    /// cascades, and a measure-count explosion zeroes out pitch.
    ///
    /// Run it in RELEASE — see `OMRRasterSeamEvalHarness`.
    @Suite(.enabled(if: ProcessInfo.processInfo.environment["OMR_HYBRID_EVAL"] == "1"))
    struct OMRHybridEvalHarness {
        static func mode() -> OMRHybridFrontEnd.Mode {
            let raw = ProcessInfo.processInfo.environment["OMR_HYBRID_MODE"] ?? "full"
            return OMRHybridFrontEnd.Mode(rawValue: raw) ?? .full
        }

        /// `OMR_HYBRID_JITTER_SP` — glyph-origin noise in staff spaces,
        /// 0 (unset) for the perfect-detector default.
        static func jitterSigma() -> Double {
            Double(ProcessInfo.processInfo.environment["OMR_HYBRID_JITTER_SP"] ?? "") ?? 0
        }

        @MainActor
        @Test func hybridAgainstSourceMscx() throws {
            guard let root = ProcessInfo.processInfo.environment["OMR_DATA_ROOT"] else {
                Issue.record("OMR_HYBRID_EVAL=1 but OMR_DATA_ROOT is unset")
                return
            }
            let mode = Self.mode()
            var rows = 0
            for dir in try OMRHarnessDirectoryWalk.renderDirectories(root: root) {
                switch Self.evaluate(dir: dir, mode: mode) {
                case .skipped: continue
                case let .row(line):
                    print(line)
                    rows += 1
                case let .failed(message):
                    print("[\((dir as NSString).lastPathComponent)] FAIL-THREW \(message)")
                }
            }
            print(
                "[hybrid][SUMMARY] mode=\(mode.rawValue) "
                    + "jitterSp=\(Self.jitterSigma()) rows=\(rows) "
                    + "peakRSS=\(OMRPageBitmapLoader.peakResidentMB())MB",
            )
        }

        enum Outcome {
            case skipped
            case row(String)
            case failed(String)
        }

        /// One render directory. Factored out of the `@Test` loop so a
        /// failure in one directory is a printed row rather than an
        /// aborted sweep — matching the other four harnesses.
        @MainActor
        static func evaluate(dir: String, mode: OMRHybridFrontEnd.Mode) -> Outcome {
            let fm = FileManager.default
            do {
                let labelNames = try OMRHarnessDirectoryWalk.labelFiles(in: dir)
                guard fm.fileExists(atPath: "\(dir)/source.mscx"), !labelNames.isEmpty
                else { return .skipped }
                let scoreA = try MSCXParser.parse(
                    contentsOf: URL(fileURLWithPath: "\(dir)/source.mscx"),
                )
                let pages = try labelNames.map {
                    try OMRLabelSchema.decode(
                        Data(contentsOf: URL(fileURLWithPath: "\(dir)/\($0)")),
                    )
                }
                let hybrid = try OMRHybridFrontEnd.compose(
                    pages: pages, analyses: analyses(dir: dir, pages: pages), mode: mode,
                    originJitterInSpaces: jitterSigma(),
                )
                let scoreB = try PDFImporter.buildScore(
                    pageCount: hybrid.pageCount, walked: hybrid.walked,
                    pageSizes: hybrid.pageSizes, documentAttributes: nil,
                    options: PDFImportOptions(),
                )
                return .row(ScoreSemanticMetrics.summaryRow(
                    tag: "[\((dir as NSString).lastPathComponent)]",
                    scoreA: scoreA, scoreB: scoreB, pdfRecovered: true,
                    aligned: ScoreSemanticMetrics.alignNotefulParts(
                        scoreA: scoreA, scoreB: scoreB,
                    ),
                    hiddenLoss: 0,
                ))
            } catch {
                return .failed("\(error)")
            }
        }

        /// Every page's raster analysis, one bitmap live at a time.
        static func analyses(
            dir: String, pages: [OMRPageLabels],
        ) -> [Int: RasterPageAnalysis] {
            var out: [Int: RasterPageAnalysis] = [:]
            for page in pages {
                let url = URL(fileURLWithPath: "\(dir)/\(page.image.file)")
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                out[page.page.index] = try? OMRPageBitmapLoader.withPageBitmap(
                    url: url, dpi: Double(page.image.dpi),
                ) { RasterPage.analyze($0, pageIndex: page.page.index) }
            }
            return out
        }
    }
#endif
