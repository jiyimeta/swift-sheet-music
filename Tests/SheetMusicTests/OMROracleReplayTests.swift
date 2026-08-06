#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicMSCX
    @testable import SheetMusicPDF
    import Testing

    enum OMROracleReplaySupport {
        /// A hand-built one-page WalkedContent that buildScore accepts:
        /// a 5-line staff (paths), a barline, a clef, and four quarter
        /// noteheads. Mirrors PDFImporterFacadeTests' proven minimum
        /// (5 horizontal lines suffice for staff detection).
        static func handContent() -> (WalkedContent, [Int: CGSize]) {
            var content = WalkedContent(glyphs: [], texts: [], paths: [], curves: [])
            for i in 0 ..< 5 {
                content.paths.append(PathSegment(
                    kind: .horizontal,
                    rect: CGRect(x: 50, y: 400 + CGFloat(i) * 8, width: 400, height: 0),
                    lineWidth: 0.6, pageIndex: 0, quad: nil,
                ))
            }
            content.paths.append(PathSegment(
                kind: .vertical,
                rect: CGRect(x: 450, y: 400, width: 0, height: 32),
                lineWidth: 1.2, pageIndex: 0, quad: nil,
            ))
            content.glyphs.append(ClassifiedGlyph(
                geometry: GlyphGeometry(
                    origin: CGPoint(x: 60, y: 408), advance: 8,
                    renderedSize: 32, pageIndex: 0, fontSize: 100,
                ),
                semantic: .clefG,
            ))
            for (i, y) in [416.0, 420.0, 424.0, 416.0].enumerated() {
                content.glyphs.append(ClassifiedGlyph(
                    geometry: GlyphGeometry(
                        origin: CGPoint(x: 120 + CGFloat(i) * 70, y: y),
                        advance: 6, renderedSize: 10, pageIndex: 0, fontSize: 100,
                    ),
                    semantic: .noteheadBlack,
                ))
            }
            return (content, [0: CGSize(width: 595, height: 842)])
        }

        static func build(_ content: WalkedContent, _ sizes: [Int: CGSize]) throws -> Score {
            try PDFImporter.buildScore(
                pageCount: 1, walked: content, pageSizes: sizes,
                documentAttributes: nil, options: .init(),
            )
        }

        /// MSCXEncoder byte-diff localizer: first differing line ±3.
        static func byteDiff(_ a: Score, _ b: Score) -> String {
            guard let da = try? MSCXEncoder.encode(a),
                  let db = try? MSCXEncoder.encode(b)
            else { return "(MSCXEncoder threw — dump unavailable)" }
            guard let sa = String(bytes: da, encoding: .utf8),
                  let sb = String(bytes: db, encoding: .utf8)
            else { return "(mscx output is not valid UTF-8 — dump unavailable)" }
            let la = sa.components(separatedBy: "\n")
            let lb = sb.components(separatedBy: "\n")
            for i in 0 ..< max(la.count, lb.count) {
                let x = i < la.count ? la[i] : "(end)"
                let y = i < lb.count ? lb[i] : "(end)"
                if x != y {
                    let lo = max(0, i - 3)
                    var out = "first mscx divergence at line \(i)\n"
                    for k in lo ... i {
                        out += "  B: \(k < la.count ? la[k] : "(end)")\n"
                        out += "  C: \(k < lb.count ? lb[k] : "(end)")\n"
                    }
                    return out
                }
            }
            return "(byte-identical mscx — Score inequality is in non-encoded fields)"
        }
    }

    struct OMROracleReplayUnitTests {
        @Test func buildScoreIsInvariantUnderCanonicalReordering() throws {
            let (content, sizes) = OMROracleReplaySupport.handContent()
            var reversed = content
            reversed.glyphs.reverse()
            reversed.paths.reverse()
            let a = try OMROracleReplaySupport.build(content, sizes)
            let b = try OMROracleReplaySupport.build(reversed, sizes)
            if a != b {
                Issue.record(Comment(
                    rawValue:
                    "ORDER SENSITIVITY — STOP, report BLOCKED (risk R9):\n"
                        + OMROracleReplaySupport.byteDiff(a, b),
                ))
            }
        }

        @Test func oracleReplayEqualsDirectBuildOnHandContent() throws {
            let (content, sizes) = OMROracleReplaySupport.handContent()
            let direct = try OMROracleReplaySupport.build(content, sizes)
            let pageSize = try #require(sizes[0])
            let labels = OMRLabelSchema.pageLabels(
                walked: content, pageIndex: 0, pageSize: pageSize,
                dpi: 300, imageFile: "page_0.png", inkBBox: { _ in nil },
            )
            let reparsed = try OMRLabelSchema.decode(OMRLabelSchema.encodeCanonical(labels))
            let replay = try OMROracleFrontEnd.replay(pages: [reparsed])
            let oracle = try PDFImporter.buildScore(
                pageCount: replay.pageCount, walked: replay.walked,
                pageSizes: replay.pageSizes, documentAttributes: nil,
                options: .init(),
            )
            if oracle != direct {
                Issue.record(Comment(rawValue: OMROracleReplaySupport.byteDiff(direct, oracle)))
            }
            #expect(oracle == direct)
        }

        /// Coverage gap closed (Task 3 review, minor finding): a quad-less
        /// `.beam` `PathSegment` — Task 2's writer keeps it in the `paths`
        /// stream (not `beams`, which requires a fitted quad) — round-trips
        /// through the label codec + oracle reconstruction. The shared
        /// `sampleContent()` fixture only carries a beam WITH a quad, so
        /// this reverse path was previously verified only by static
        /// inspection of `OMRLabelSchema.pathLabels` /
        /// `OMROracleFrontEnd.paths`. This test does not touch `buildScore`
        /// — it targets the label round-trip directly, which is the layer
        /// the gap is actually in.
        @Test func quadLessBeamPathRoundTripsThroughLabels() throws {
            var content = WalkedContent(glyphs: [], texts: [], paths: [], curves: [])
            content.paths.append(PathSegment(
                kind: .beam,
                rect: CGRect(x: 100, y: 200, width: 40, height: 6),
                lineWidth: 1.0, pageIndex: 0, quad: nil,
            ))
            let labels = OMRLabelSchema.pageLabels(
                walked: content, pageIndex: 0, pageSize: CGSize(width: 595, height: 842),
                dpi: 300, imageFile: "page_0.png", inkBBox: { _ in nil },
            )
            #expect(labels.beams.isEmpty)
            #expect(labels.paths.count == 1)
            #expect(labels.paths.first?.kind == "beam")

            let reparsed = try OMRLabelSchema.decode(OMRLabelSchema.encodeCanonical(labels))
            let replay = try OMROracleFrontEnd.replay(pages: [reparsed])
            #expect(replay.walked.paths == content.paths)
        }

        /// Whole-branch review, Important 1: the gate's closing line used
        /// to read `exact=\(exact)/\(total)` where `total` counted ONLY
        /// the renders that reached `.exact` or `.inexact`. A sweep where
        /// label export had been skipped, or where every PDF failed to
        /// open, printed `exact=0/0` — "both numbers equal", which is the
        /// pass criterion the runbook states — and passed vacuously.
        /// Partial failures shrank the denominator instead of showing as
        /// misses. `Tally` is the fix: every visited directory counts, so
        /// a skip or a throw can only ever make `exact < total`, and an
        /// empty sweep is a failure rather than a perfect score.
        @Test func gateTallyCountsEveryOutcomeAndCannotPassVacuously() {
            let empty = OMROracleReplayGate.Tally()
            #expect(empty.total == 0)
            #expect(empty.passes == false) // total == 0 is a FAILURE, not 0/0
            #expect(
                OMROracleReplayGate.summaryLine(empty)
                    == "[gate][SUMMARY] P0-G1 exact=0/0 inexact=0 skipped=0 failed=0 pass=N",
            )

            var mixed = OMROracleReplayGate.Tally()
            mixed.record(.exact)
            mixed.record(.exact)
            mixed.record(.skippedNoLabels)
            mixed.record(.failed("could not open score.pdf"))
            mixed.record(.inexact(diff: "line 12"))
            #expect(mixed == OMROracleReplayGate.Tally(
                exact: 2, inexact: 1, skippedNoLabels: 1, failed: 1,
            ))
            // The denominator counts all five, so the two skipped/failed
            // renders are visible as misses instead of vanishing.
            #expect(mixed.total == 5)
            #expect(mixed.passes == false)
            #expect(
                OMROracleReplayGate.summaryLine(mixed)
                    == "[gate][SUMMARY] P0-G1 exact=2/5 inexact=1 skipped=1 failed=1 pass=N",
            )

            // A skip alone is enough to fail — it is the exact shape that
            // used to print `exact=0/0 pass`.
            var skippedOnly = OMROracleReplayGate.Tally()
            skippedOnly.record(.skippedNoLabels)
            #expect(skippedOnly.total == 1)
            #expect(skippedOnly.passes == false)
            #expect(
                OMROracleReplayGate.summaryLine(skippedOnly)
                    == "[gate][SUMMARY] P0-G1 exact=0/1 inexact=0 skipped=1 failed=0 pass=N",
            )

            var allExact = OMROracleReplayGate.Tally()
            allExact.record(.exact)
            allExact.record(.exact)
            #expect(allExact.total == 2)
            #expect(allExact.passes)
            #expect(
                OMROracleReplayGate.summaryLine(allExact)
                    == "[gate][SUMMARY] P0-G1 exact=2/2 inexact=0 skipped=0 failed=0 pass=Y",
            )
        }
    }

    /// Gate P0-G1 (spec §4.4): oracle replay == direct vector import,
    /// per render, over the dataset. No-op unless OMR_ORACLE_REPLAY=1.
    /// Score B is built through walkDocument+buildScore with the SAME
    /// forced-Tier-1 flags label export used and documentAttributes:nil
    /// (judgment call 3 in the plan header).
    @Suite(.enabled(if: ProcessInfo.processInfo.environment["OMR_ORACLE_REPLAY"] == "1"))
    struct OMROracleReplayGate {
        /// One render directory's outcome. Not `private`, and factored out
        /// of the `@Test` loop below, so Task 9's `OMRHarnessWiringTests`
        /// can drive the labels-discovery → walk → replay → compare
        /// wiring directly against a synthetic fixture, without needing
        /// `OMR_DATA_ROOT`. The printed `[SUMMARY]` lines and the
        /// `exact`/`total` counting in
        /// `oracleReplayMatchesDirectImportForEveryRender` below are
        /// unchanged for every directory that reaches a summary line —
        /// only re-expressed as a switch over this.
        ///
        /// ONE DELIBERATE BEHAVIOR CHANGE (Task 9 review, finding 1): the
        /// `.labels.json` listing (`OMRHarnessDirectoryWalk.labelFiles`)
        /// used to sit OUTSIDE the original `do { … } catch { … }`, so a
        /// listing failure (e.g. a directory removed mid-sweep) threw out
        /// of the `for dir in renderDirs` loop and failed the whole
        /// `@Test`, aborting the batch with no per-directory line and no
        /// final `[gate][SUMMARY]` line. Here it is INSIDE the do-block,
        /// so that failure is caught, returned as `.failed`, printed as a
        /// per-directory `FAIL-THREW` line, and the sweep continues —
        /// matching how every other failure in this function (and every
        /// other harness) already behaves. This is an improvement, kept
        /// intentionally: a dataset sweep must not let one bad directory
        /// abort the whole gate.
        enum RenderOutcome {
            case skippedNoLabels
            case exact
            case inexact(diff: String)
            case failed(String)
        }

        /// The sweep's running tally, and the sole source of the closing
        /// `[gate][SUMMARY]` line.
        ///
        /// Whole-branch review, Important 1: `total` counts EVERY render
        /// directory the sweep visited, including the ones that were
        /// skipped for want of labels and the ones that threw. It used to
        /// count only `.exact` + `.inexact`, which made the runbook's
        /// stated criterion ("`exact=N/N`, both numbers equal") vacuously
        /// satisfiable — a run where label export had never happened, or
        /// where every PDF failed to open, printed `exact=0/0` and read
        /// as a pass, and any partial failure shrank the denominator
        /// instead of showing up as a miss. This is the gate that
        /// certifies the label format lossless, so a false pass here is
        /// the most expensive failure mode in the branch.
        ///
        /// `passes` therefore also treats an empty sweep as a FAILURE
        /// (`total > 0 &&`), mirroring the Python side's
        /// `print_faces_report`, whose exit code is
        /// `0 if total and not report["unconfirmed"] else 1`.
        struct Tally: Equatable {
            var exact = 0
            var inexact = 0
            var skippedNoLabels = 0
            var failed = 0

            var total: Int {
                exact + inexact + skippedNoLabels + failed
            }

            var passes: Bool {
                total > 0 && exact == total
            }

            mutating func record(_ outcome: RenderOutcome) {
                switch outcome {
                case .exact: exact += 1
                case .inexact: inexact += 1
                case .skippedNoLabels: skippedNoLabels += 1
                case .failed: failed += 1
                }
            }
        }

        static func summaryLine(_ tally: Tally) -> String {
            "[gate][SUMMARY] P0-G1 exact=\(tally.exact)/\(tally.total) "
                + "inexact=\(tally.inexact) skipped=\(tally.skippedNoLabels) "
                + "failed=\(tally.failed) pass=\(tally.passes ? "Y" : "N")"
        }

        @MainActor
        static func evaluateOneRender(dir: String) -> RenderOutcome {
            do {
                let labelPaths = try OMRHarnessDirectoryWalk.labelFiles(in: dir)
                guard !labelPaths.isEmpty else { return .skippedNoLabels }
                let renderData = try Data(contentsOf: URL(fileURLWithPath: "\(dir)/render.json"))
                let render = try JSONSerialization.jsonObject(with: renderData) as? [String: Any]
                let pdfName = render?["pdf"] as? String ?? "score.pdf"
                let pdfData = try Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(pdfName)"))
                let document = try PDFImporter.openDocument(pdfData)
                let walk = try PDFImporter.walkDocument(
                    document, anchorMusicGlyphsToPUARange: true,
                )
                let scoreB = try PDFImporter.buildScore(
                    pageCount: document.pageCount, walked: walk.content,
                    pageSizes: walk.pageSizes, documentAttributes: nil,
                    options: .init(),
                )
                let pages = try labelPaths.map {
                    try OMRLabelSchema.decode(
                        Data(contentsOf: URL(fileURLWithPath: "\(dir)/\($0)")),
                    )
                }
                let replay = try OMROracleFrontEnd.replay(pages: pages)
                let scoreC = try PDFImporter.buildScore(
                    pageCount: replay.pageCount, walked: replay.walked,
                    pageSizes: replay.pageSizes, documentAttributes: nil,
                    options: .init(),
                )
                if scoreC == scoreB {
                    return .exact
                }
                return .inexact(diff: OMROracleReplaySupport.byteDiff(scoreB, scoreC))
            } catch {
                return .failed("\(error)")
            }
        }

        @MainActor
        @Test func oracleReplayMatchesDirectImportForEveryRender() throws {
            guard let root = ProcessInfo.processInfo.environment["OMR_DATA_ROOT"] else {
                Issue.record("OMR_ORACLE_REPLAY=1 but OMR_DATA_ROOT is unset")
                return
            }
            let renderDirs = try OMRHarnessDirectoryWalk.renderDirectories(root: root)
            var tally = Tally()
            for dir in renderDirs {
                let renderID = (dir as NSString).lastPathComponent
                let tag = "[\(renderID)]"
                let outcome = Self.evaluateOneRender(dir: dir)
                tally.record(outcome)
                switch outcome {
                case .skippedNoLabels:
                    print("\(tag)[SUMMARY] SKIP-NO-LABELS")
                case .exact:
                    print("\(tag)[SUMMARY] exact=Y")
                case let .inexact(diff):
                    print("\(tag)[SUMMARY] exact=N")
                    print("\(tag)[diff] \(diff)")
                case let .failed(message):
                    print("\(tag)[SUMMARY] FAIL-THREW \(message)")
                }
            }
            print(Self.summaryLine(tally))
            // The printed line is no longer the only signal: a sweep that
            // skipped, threw, or found nothing at all now fails the test
            // outright, so an operator who reads only `swift test`'s
            // verdict cannot mistake a vacuous `exact=0/0` for a pass.
            if !tally.passes {
                Issue.record(Comment(
                    rawValue:
                    "P0-G1 FAILED — \(Self.summaryLine(tally)). "
                        + "A skipped or failed render counts as a miss; "
                        + "`total == 0` means the sweep found no render "
                        + "directory under OMR_DATA_ROOT at all.",
                ))
            }
        }
    }
#endif
