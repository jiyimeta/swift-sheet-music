#if !os(Android)
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicLoader
    @testable import SheetMusicPDF

    /// Ground-truth sweep over a `.mscz` corpus (`scripts/mscz-corpus-prep.sh`
    /// prepared the PDFs).
    ///
    ///     .mscz ──MuseScore CLI──> PDF ──rasterize──> image-only PDF ──> Score
    ///       └──────────────────── ground truth ──────────────────────────┘
    ///
    /// Every file carries its own answer, which no copyrighted-PDF corpus can
    /// offer, and the engraving is MuseScore's real one rather than the
    /// training generator's — the axis the synthetic eval set cannot cover.
    ///
    /// Runs in one of two modes, and a round normally runs BOTH:
    ///
    /// - `.vector` reads the typeset PDF with today's default options. This
    ///   is the CEILING, not a control to be skipped: it is the same
    ///   documents, the same metric functions and the same ground truth, so
    ///   `raster` minus `vector` is what the OMR path costs. An absolute
    ///   raster percentage on a corpus nobody has measured before says
    ///   nothing on its own — a low number could as easily be this corpus
    ///   being hard, or the importer being weak somewhere with no OMR in it
    ///   at all.
    /// - `.raster` re-wraps the same PDF as images (`MSCZScanSimulator`) and
    ///   reads it through `omrTileClassifier`.
    @MainActor
    enum MSCZGroundTruthSweep {
        enum Mode: String {
            case vector
            case raster
        }

        /// One corpus entry: the score and the PDF MuseScore made from it.
        struct Case {
            var mscz: URL
            var pdf: URL
            /// Path shown in the per-file row, relative to the corpus root,
            /// so a row names a score rather than a 90-character path.
            var name: String
        }

        struct Totals {
            var files = 0
            /// Both sides parsed and the score-level metric was computed.
            var scored = 0
            /// The ground-truth `.mscz` itself would not load. Counted apart
            /// from `failed`: nothing was measured, but nothing about the
            /// importer was measured either.
            var truthFailed = 0
            /// The PDF side threw — for `.raster` that includes "the page
            /// yielded nothing", which is a real result, not a harness fault.
            var failed = 0
            var pitchPcts: [Double] = []
            var durPcts: [Double] = []
            var notesTruth = 0
            var notesRead = 0
        }

        /// Pair every `*.mscz` under `msczRoot` with the PDF the prep script
        /// wrote at the same relative path under `pdfRoot`.
        ///
        /// Sorted by relative path and truncated AFTER sorting, so `limit`
        /// selects the same prefix on every run: a sweep whose population
        /// changes between runs cannot be compared against its own earlier
        /// numbers, which is the whole point of running it twice.
        /// `matching`, when set, keeps only the scores whose relative path
        /// contains it. A 657-file sweep takes the better part of an hour, and
        /// reading one file's rows is otherwise an hour's wait — which is
        /// enough friction to make "look at the actual divergence" the step
        /// that gets skipped in favor of guessing from the summary row.
        static func cases(
            msczRoot: URL, pdfRoot: URL, limit: Int, matching: String? = nil,
        ) -> [Case] {
            let root = msczRoot.standardizedFileURL.path
            let walker = FileManager.default.enumerator(atPath: root)
            var relatives: [String] = []
            while let entry = walker?.nextObject() as? String {
                if entry.hasSuffix(".mscz") { relatives.append(entry) }
            }
            if let matching { relatives = relatives.filter { $0.contains(matching) } }
            var out: [Case] = []
            for relative in relatives.sorted() {
                let pdf = pdfRoot.appendingPathComponent(
                    (relative as NSString).deletingPathExtension + ".pdf",
                )
                guard FileManager.default.fileExists(atPath: pdf.path) else { continue }
                out.append(Case(
                    mscz: msczRoot.appendingPathComponent(relative), pdf: pdf, name: relative,
                ))
                if limit > 0, out.count >= limit { break }
            }
            return out
        }

        /// NON-THROWING per file, like `applyRasterFallback` itself: one
        /// unreadable score in a 669-file corpus must cost that file's row,
        /// not the run. The counters above are what makes a skipped file
        /// visible, since a sweep that quietly drops its hard cases reports
        /// the average of its easy ones.
        static func sweep(
            cases: [Case], mode: Mode, scanDPI: Double, options: PDFImportOptions,
            dumpDivergence: Bool = false,
        ) -> Totals {
            var totals = Totals()
            for item in cases {
                totals.files += 1
                guard let truth = loadTruth(item, totals: &totals) else { continue }
                do {
                    let read = try autoreleasepool {
                        try readPDF(item, mode: mode, scanDPI: scanDPI, options: options)
                    }
                    score(item, truth: truth, read: read, mode: mode, totals: &totals)
                    if dumpDivergence { dump(item, truth: truth, read: read, mode: mode) }
                } catch {
                    totals.failed += 1
                    print("[mscz-fail] mode=\(mode.rawValue) file=\(item.name) error=\(error)")
                }
            }
            return totals
        }

        private static func loadTruth(_ item: Case, totals: inout Totals) -> Score? {
            do {
                return try ScoreLoader.loadScore(contentsOf: item.mscz)
            } catch {
                totals.truthFailed += 1
                print("[mscz-truth-fail] file=\(item.name) error=\(error)")
                return nil
            }
        }

        private static func readPDF(
            _ item: Case, mode: Mode, scanDPI: Double, options: PDFImportOptions,
        ) throws -> Score {
            switch mode {
            case .vector:
                return try PDFImporter.parse(pdfURL: item.pdf, options: options)
            case .raster:
                let data = try MSCZScanSimulator.imageOnlyPDF(of: item.pdf, dpi: scanDPI)
                return try PDFImporter.parse(pdfData: data, options: options)
            }
        }

        /// One file's row plus its contribution to the totals. The row is
        /// `ScoreSemanticMetrics.summaryRow`, unchanged, so these numbers sit
        /// in the same TSV shape as the synthetic and real-corpus sweeps.
        private static func score(
            _ item: Case, truth: Score, read: Score, mode: Mode, totals: inout Totals,
        ) {
            let aligned = ScoreSemanticMetrics.alignNotefulParts(scoreA: truth, scoreB: read)
            print(ScoreSemanticMetrics.summaryRow(
                tag: "[mscz-\(mode.rawValue)][\(item.name)]", scoreA: truth, scoreB: read,
                pdfRecovered: true, aligned: aligned, hiddenLoss: 0,
            ))
            totals.scored += 1
            totals.notesTruth += ScoreSemanticMetrics.contentTotals(truth).notes
            totals.notesRead += ScoreSemanticMetrics.contentTotals(read).notes
            let pitch = ScoreSemanticMetrics.measureAlignedPitchMatch(
                scoreA: aligned.scoreA, scoreB: aligned.scoreB,
            )
            if pitch.pos.c > 0 {
                totals.pitchPcts.append(Double(pitch.pos.m) / Double(pitch.pos.c))
            }
            let dur = ScoreSemanticMetrics.measureAlignedDurationMatch(
                scoreA: aligned.scoreA, scoreB: aligned.scoreB,
            )
            if dur.match.c > 0 {
                totals.durPcts.append(Double(dur.match.m) / Double(dur.match.c))
            }
        }

        /// What the summary row cannot say: WHERE the two scores stop
        /// agreeing, and what each side actually holds there.
        ///
        /// A row like `pitch%=0% dur%=100%` — every duration right, every
        /// pitch wrong — has at least two explanations that call for fixes in
        /// completely different places: the read staves paired in a different
        /// order than the truth's (this harness's alignment), or every pitch
        /// off by a constant (a misread clef). The summary row cannot tell
        /// them apart, and the measure dump can.
        ///
        /// Prints the staff layout of both sides too, since a part/staff
        /// regrouping is the alignment hypothesis's own signature.
        private static func dump(_ item: Case, truth: Score, read: Score, mode: Mode) {
            let tag = "[mscz-diverge][\(mode.rawValue)][\(item.name)]"
            for (label, score) in [("A(truth)", truth), ("B(read)", read)] {
                let shape = score.parts.map { part in
                    part.staves.map { staff in
                        "\(ScoreSemanticMetrics.staffIsPercussion(staff) ? "perc" : "pitched")"
                            + ":\(staff.measures.count)m"
                    }.joined(separator: "+")
                }.joined(separator: " | ")
                print("\(tag) \(label) parts=[\(shape)]")
            }
            let aligned = ScoreSemanticMetrics.alignNotefulParts(scoreA: truth, scoreB: read)
            let report = ScoreSemanticMetrics.firstDivergenceReport(
                scoreA: aligned.scoreA, scoreB: aligned.scoreB,
            )
            for line in (report ?? "no divergence").split(separator: "\n") {
                print("\(tag) \(line)")
            }
        }

        /// `n/a` rather than `0.0000` over an empty population, for the
        /// reason `OMRDetectorEvalHarness.printScoreSummary` gives: a zero
        /// that means "nothing was scored" reads as a real, terrible score.
        static func summaryLine(mode: Mode, totals: Totals) -> String {
            func fmt(_ values: [Double], _ stat: ([Double]) -> Double) -> String {
                values.isEmpty ? "n/a" : String(format: "%.4f", stat(values))
            }
            func mean(_ values: [Double]) -> Double {
                values.reduce(0, +) / Double(values.count)
            }
            return "[mscz][SUMMARY] mode=\(mode.rawValue) files=\(totals.files) "
                + "scored=\(totals.scored) truthFailed=\(totals.truthFailed) "
                + "failed=\(totals.failed) "
                + "pitchP50=\(fmt(totals.pitchPcts) { OMRDetectorMetrics.percentile($0, 0.5) }) "
                + "pitchMean=\(fmt(totals.pitchPcts, mean)) "
                + "durP50=\(fmt(totals.durPcts) { OMRDetectorMetrics.percentile($0, 0.5) }) "
                + "durMean=\(fmt(totals.durPcts, mean)) "
                + "notesTruth=\(totals.notesTruth) notesRead=\(totals.notesRead)"
        }
    }
#endif
