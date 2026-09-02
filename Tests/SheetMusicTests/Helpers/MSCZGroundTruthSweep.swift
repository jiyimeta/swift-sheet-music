#if !os(Android) && !os(WASI)
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

        /// How many glyphs of each class each front-end saw on the same
        /// document — the step BEFORE asking why a score came out wrong.
        ///
        /// A missing clef in the built score has two possible causes needing
        /// fixes in unrelated places: the detector never saw the glyph, or it
        /// saw it and something downstream refused it. Counting classes tells
        /// them apart, and does it WITHOUT reconciling the two front-ends'
        /// coordinate frames — the raster analysis frame and the PDF's page
        /// space differ on a resampled page, so any position-based comparison
        /// would need reframing first and would confound a frame bug with a
        /// detection one. Counts need no frame at all.
        ///
        /// The vector walk is a legitimate truth here for exactly the reason
        /// the sweep runs both modes: it reads the same document, and its
        /// score against the `.mscz` is 0.99.
        static func glyphCensus(_ item: Case, scanDPI: Double, options: PDFImportOptions) throws {
            let vector = try PDFImporter.walkDocument(
                PDFImporter.openDocument(Data(contentsOf: item.pdf)),
            ).content.glyphs
            var raster: [ClassifiedGlyph] = []
            if let detector = try PDFImporter.rasterDetector(for: options) {
                let scan = try PDFImporter.openDocument(
                    MSCZScanSimulator.imageOnlyPDF(of: item.pdf, dpi: scanDPI),
                )
                for index in 0 ..< scan.pageCount {
                    guard let page = scan.page(at: index)?.pageRef else { continue }
                    try autoreleasepool {
                        let bitmap = try PDFPageRasterizer.bitmap(page: page, dpi: scanDPI)
                        raster += try RasterFrontEnd.page(
                            bitmap: bitmap, pageIndex: index, detector: detector,
                            diagnostics: nil,
                        ).walked.glyphs
                    }
                }
            }
            printCensus(item, vector: vector, raster: raster)
        }

        /// Where a detected clef goes: onto the staff that needs it, onto
        /// another one, or nowhere.
        ///
        /// `scoreStateEvents` reads a clef out of a MEASURE's glyph list, and
        /// a staff whose clef never lands there is read as treble. The census
        /// above proves the clef was detected on the page; this counts how
        /// many of those survive into a measure, which splits the remaining
        /// question in two — and the two halves want fixes in unrelated
        /// places:
        ///
        ///   `inMeasures < onPage`   the clef is captured by NO staff, so the
        ///                           question is `filterGlyphs`' band or the
        ///                           staff's x range;
        ///   `inMeasures == onPage`  it is captured by the WRONG staff, so the
        ///                           question is the origin the detector
        ///                           reports for a tall glyph.
        ///
        /// A third mechanism hides behind the second and gets its own count:
        /// `readClef` scans a measure only up to its first NOTEHEAD, so a clef
        /// sitting in the right measure but ordered after one is never read.
        /// Without `behindNotehead` that case is indistinguishable from
        /// wrong-staff capture, and it wants a third fix again.
        ///
        /// Both counts are taken for both front-ends, because the number that
        /// matters is the DIFFERENCE: the vector walk runs the same structure
        /// pass over the same document, so whatever it does is what "working"
        /// looks like here.
        static func clefCapture(_ item: Case, scanDPI: Double, options: PDFImportOptions) throws {
            let vector = try PDFImporter.walkDocument(
                PDFImporter.openDocument(Data(contentsOf: item.pdf)),
            )
            let vectorAccidentals = report(
                item, mode: "vector", walked: vector.content, pageCount: vector.pageSizes.count,
            )
            guard let detector = try PDFImporter.rasterDetector(for: options) else { return }
            let scan = try PDFImporter.openDocument(
                MSCZScanSimulator.imageOnlyPDF(of: item.pdf, dpi: scanDPI),
            )
            var raster = WalkedContent(glyphs: [], texts: [], paths: [], curves: [])
            for index in 0 ..< scan.pageCount {
                guard let page = scan.page(at: index)?.pageRef else { continue }
                try autoreleasepool {
                    let bitmap = try PDFPageRasterizer.bitmap(page: page, dpi: scanDPI)
                    let one = try RasterFrontEnd.page(
                        bitmap: bitmap, pageIndex: index, detector: detector, diagnostics: nil,
                    ).walked
                    raster.glyphs += one.glyphs
                    raster.paths += one.paths
                }
            }
            let rasterAccidentals = report(
                item, mode: "raster", walked: raster, pageCount: scan.pageCount,
            )
            compareAccidentals(item, vector: vectorAccidentals, raster: rasterAccidentals)
            clefProbe(item, vector: vector.content, raster: raster)
        }

        /// What the raster front-end put where the vector one read a clef.
        ///
        /// `stavesWithClef` says a staff HAS no clef; it cannot say whether
        /// the detector proposed the wrong class there, proposed nothing, or
        /// put the right glyph somewhere the capture band could not reach.
        /// Those three want fixes in three different places (training data,
        /// decode threshold, capture geometry), so the probe holds the two
        /// front-ends' glyph lists side by side at the SAME page coordinate
        /// and prints the raster neighborhood of every vector clef.
        ///
        /// Gated on `OMR_MSCZ_CLEF_PROBE=1` — one line per clef in the
        /// document, which is 138 lines for a 23-system sextet.
        private static func clefProbe(
            _ item: Case, vector: WalkedContent, raster: WalkedContent,
        ) {
            guard ProcessInfo.processInfo.environment["OMR_MSCZ_CLEF_PROBE"] == "1" else { return }
            // A clef is ~4 staff spaces tall, so a neighborhood of 12pt at
            // MuseScore's default staff size covers the glyph and a little
            // around it without reaching the next staff.
            let radius: CGFloat = 12
            for clef in vector.glyphs where isClef(clef) {
                let page = clef.geometry.pageIndex
                let at = clef.geometry.origin
                let near = raster.glyphs
                    .filter { $0.geometry.pageIndex == page }
                    .map { ($0, hypot($0.geometry.origin.x - at.x, $0.geometry.origin.y - at.y)) }
                    .filter { $0.1 <= radius }
                    .sorted { $0.1 < $1.1 }
                    .map { "\(OMRLabelClassNames.className(for: $0.0.semantic))@\(round($0.1 * 10) / 10)" }
                print("[mscz-clefprobe][\(item.name)] page=\(page) "
                    + "vector=\(OMRLabelClassNames.className(for: clef.semantic)) "
                    + "at=(\(round(at.x * 10) / 10),\(round(at.y * 10) / 10)) "
                    + "raster=[\(near.joined(separator: " "))]")
            }
        }

        private static func isAccidental(_ glyph: ClassifiedGlyph) -> Bool {
            OMRLabelClassNames.className(for: glyph.semantic).hasPrefix("accidental")
        }

        /// The structure pass, in `buildScore`'s own order — canonicalize,
        /// detect staves per page, derive ONE document-wide ensemble size,
        /// then lay out systems. Reproducing the order matters: the ensemble
        /// size is a document-wide input to every page's system clustering,
        /// so a per-page shortcut here would measure a pipeline the importer
        /// never runs.
        /// Returns each staff's accidental count, in traversal order, so the
        /// caller can hold the two front-ends' lists side by side.
        @discardableResult
        private static func report(
            _ item: Case, mode: String, walked incoming: WalkedContent, pageCount: Int,
        ) -> [Int] {
            let walked = incoming.canonicalized()
            var stavesByPage: [[SheetMusicPDF.Staff]] = []
            for page in 0 ..< pageCount {
                stavesByPage.append(PDFImporter.detectStaves(
                    paths: walked.paths.filter { $0.pageIndex == page },
                    classified: walked.glyphs.filter { $0.geometry.pageIndex == page },
                    pageIndex: page,
                ))
            }
            let ensembleSize = PDFImporter.ensembleStaffCount(stavesByPage)
            var staves = 0
            var stavesWithClef = 0
            var inMeasures = 0
            var behindNotehead = 0
            var inForce: [String: Int] = [:]
            var accidentalsPerStaff: [Int] = []
            for page in 0 ..< pageCount {
                for system in PDFImporter.layoutSystems(
                    staves: stavesByPage[page], paths: walked.paths,
                    classified: walked.glyphs, pageIndex: page, ensembleSize: ensembleSize,
                ) {
                    for part in system.parts {
                        for staff in part.staves {
                            staves += 1
                            var clefs = 0
                            for measure in staff.measures {
                                let counts = clefCounts(measure)
                                clefs += counts.total
                                behindNotehead += counts.behindNotehead
                            }
                            inMeasures += clefs
                            if clefs > 0 { stavesWithClef += 1 }
                            inForce[firstClefClass(staff) ?? "(none)", default: 0] += 1
                            accidentalsPerStaff.append(staff.measures.reduce(0) { total, measure in
                                total + measure.glyphs.count(where: isAccidental)
                            })
                        }
                    }
                }
            }
            let onPage = walked.glyphs.count(where: isClef)
            print("[mscz-clefcap][\(mode)][\(item.name)] onPage=\(onPage) "
                + "inMeasures=\(inMeasures) behindNotehead=\(behindNotehead) "
                + "staves=\(staves) stavesWithClef=\(stavesWithClef)")
            for name in inForce.keys.sorted() {
                print("[mscz-inforce][\(mode)][\(item.name)] clef=\(name) staves=\(inForce[name] ?? 0)")
            }
            return accidentalsPerStaff
        }

        /// Does an accidental leave one staff and arrive on its neighbour?
        ///
        /// That is the shape a capture-band bug takes, and it is the last
        /// standing explanation for a key block whose positions match the F
        /// ladder on a staff the reader holds under a G clef: the accidentals
        /// belong to the staff below and were captured by the one above.
        ///
        /// A TRANSFER and a plain miscount look the same in a total, so the
        /// two are separated here: a staff that loses `n` while an ADJACENT
        /// staff gains `n` is a transfer; a staff that loses with no
        /// neighbouring gain is a detection difference. Index-wise, because
        /// both front-ends walk page → system → part → staff in the same
        /// order — and refused outright when the staff counts differ, since
        /// then position `i` is not the same staff on both sides and every
        /// number below would be fiction.
        private static func compareAccidentals(
            _ item: Case, vector: [Int], raster: [Int],
        ) {
            let tag = "[mscz-accshift][\(item.name)]"
            guard vector.count == raster.count else {
                print("\(tag) staffCount vector=\(vector.count) raster=\(raster.count)"
                    + " — not comparable staff by staff")
                return
            }
            var transferred = 0
            var unpaired = 0
            var lines: [String] = []
            for (index, (v, r)) in zip(vector, raster).enumerated() where v != r {
                let delta = r - v
                let neighbours = [index - 1, index + 1].filter { vector.indices.contains($0) }
                let paired = neighbours.contains { raster[$0] - vector[$0] == -delta }
                if paired { transferred += 1 } else { unpaired += 1 }
                if lines.count < 12 {
                    lines.append("\(tag) staff=\(index) vector=\(v) raster=\(r) "
                        + "delta=\(delta > 0 ? "+" : "")\(delta) "
                        + "neighbourOffsets=\(neighbours.map { raster[$0] - vector[$0] }) "
                        + "\(paired ? "TRANSFER" : "unpaired")")
                }
            }
            for line in lines {
                print(line)
            }
            print("\(tag) staves=\(vector.count) differing=\(transferred + unpaired) "
                + "transfer=\(transferred) unpaired=\(unpaired)")
        }

        /// The clef class `readClef` would put in force for this staff: the
        /// first one it meets scanning each measure in x-order, stopping at
        /// the measure's first notehead — its own rule, mirrored.
        ///
        /// Counting the clef that is IN FORCE, rather than the clefs present,
        /// is the distinction the earlier counts could not make: a staff can
        /// hold its correct clef and still be read under a different one, if a
        /// spurious detection precedes it.
        private static func firstClefClass(_ staff: ImportStaff) -> String? {
            for measure in staff.measures {
                let sorted = measure.glyphs.sorted { $0.geometry.origin.x < $1.geometry.origin.x }
                for glyph in sorted {
                    if isClef(glyph) {
                        return OMRLabelClassNames.className(for: glyph.semantic)
                    }
                    if PDFImporter.isNotehead(glyph.semantic) { break }
                }
            }
            return nil
        }

        /// Classified test-side rather than through the importer's own
        /// `clef(for:)`, which is private — the same vocabulary the census
        /// uses, so the two numbers are comparable.
        private static func isClef(_ glyph: ClassifiedGlyph) -> Bool {
            OMRLabelClassNames.className(for: glyph.semantic).hasPrefix("clef")
        }

        /// A measure's clefs, and how many of them `readClef` can never see
        /// because a notehead precedes them in x-order.
        private static func clefCounts(_ measure: ImportMeasure) -> (total: Int, behindNotehead: Int) {
            let sorted = measure.glyphs.sorted { $0.geometry.origin.x < $1.geometry.origin.x }
            var total = 0
            var behind = 0
            var sawNotehead = false
            for glyph in sorted {
                if isClef(glyph) {
                    total += 1
                    if sawNotehead { behind += 1 }
                } else if PDFImporter.isNotehead(glyph.semantic) {
                    sawNotehead = true
                }
            }
            return (total, behind)
        }

        private static func printCensus(
            _ item: Case, vector: [ClassifiedGlyph], raster: [ClassifiedGlyph],
        ) {
            func histogram(_ glyphs: [ClassifiedGlyph]) -> [String: Int] {
                var out: [String: Int] = [:]
                for glyph in glyphs {
                    out[OMRLabelClassNames.className(for: glyph.semantic), default: 0] += 1
                }
                return out
            }
            let (v, r) = (histogram(vector), histogram(raster))
            let tag = "[mscz-census][\(item.name)]"
            for name in Set(v.keys).union(r.keys).sorted() {
                print("\(tag) class=\(name) vector=\(v[name] ?? 0) raster=\(r[name] ?? 0)")
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
