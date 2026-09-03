#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicOMRModel
    @testable import SheetMusicPDF
    import Testing

    /// Ground-truth sweep over a local `.mscz` corpus. Gated on
    /// `OMR_MSCZ_EVAL=1`, and driven by `scripts/mscz-corpus-eval.sh` — see
    /// `MSCZGroundTruthSweep` for what it measures and why both modes run.
    ///
    ///     OMR_MSCZ_EVAL=1 OMR_MSCZ_ROOT=~/Documents/MuseScore3 \
    ///     OMR_MSCZ_PDF_ROOT=~/omr-mscz-corpus/pdf OMR_MSCZ_LIMIT=20 \
    ///         swift test -c release --no-parallel --filter MSCZGroundTruthEvalHarness
    @Suite(.enabled(if: ProcessInfo.processInfo.environment["OMR_MSCZ_EVAL"] == "1"))
    struct MSCZGroundTruthEvalHarness {
        static func env(_ key: String) -> String? {
            ProcessInfo.processInfo.environment[key]
        }

        static func doubleEnv(_ key: String, default fallback: Double) -> Double {
            Double(env(key) ?? "") ?? fallback
        }

        /// `0` means "every file". A default of 20 rather than the whole
        /// corpus is deliberate: the first thing to establish is that the
        /// mechanism produces sane rows, and a 669-file run is a long way to
        /// go before finding out it does not.
        static func limit() -> Int {
            Int(env("OMR_MSCZ_LIMIT") ?? "") ?? 20
        }

        @MainActor
        @Test func bothFrontEndsAgainstTheirSourceScores() async throws {
            guard let msczRoot = Self.env("OMR_MSCZ_ROOT"),
                  let pdfRoot = Self.env("OMR_MSCZ_PDF_ROOT")
            else {
                Issue.record("OMR_MSCZ_EVAL=1 but OMR_MSCZ_ROOT / OMR_MSCZ_PDF_ROOT is unset")
                return
            }
            let cases = MSCZGroundTruthSweep.cases(
                msczRoot: URL(fileURLWithPath: msczRoot, isDirectory: true),
                pdfRoot: URL(fileURLWithPath: pdfRoot, isDirectory: true),
                limit: Self.limit(), matching: Self.env("OMR_MSCZ_ONLY"),
            )
            guard !cases.isEmpty else {
                Issue.record("no .mscz/.pdf pairs under \(msczRoot) + \(pdfRoot) — run the prep script")
                return
            }
            print("[mscz] pairs=\(cases.count)")
            let scanDPI = Self.doubleEnv("OMR_MSCZ_SCAN_DPI", default: 300)
            Self.proveTheRasterPathIsLoadBearing(cases[0], scanDPI: scanDPI)
            // Off by default: one dump is several lines per file, which over
            // a 657-file sweep buries the rows the sweep exists to produce.
            let dump = Self.env("OMR_MSCZ_DIVERGENCE") == "1"
            // `OMR_MSCZ_PROBES_ONLY=1` runs the census / clef probes and
            // skips both score-level sweeps. The probes are what a decode
            // sweep at τ=0.02 is run FOR — the score-level rows at that τ
            // are junk and cost the same 15 minutes per 200 files.
            let probesOnly = Self.env("OMR_MSCZ_PROBES_ONLY") == "1"

            var vectorOptions = PDFImportOptions()
            // Attached to BOTH modes, deliberately. A diagnostic the importer
            // emits is emitted for every caller, so a new one has to be shown
            // NOT to fire on ordinary vector documents before it ships — and
            // this corpus is the only place that can be measured.
            vectorOptions.diagnostics = Self.diagnosticSink(mode: "vector")
            if !probesOnly {
                let vector = MSCZGroundTruthSweep.sweep(
                    cases: cases, mode: .vector, scanDPI: scanDPI, options: vectorOptions,
                    dumpDivergence: dump,
                )
                print(MSCZGroundTruthSweep.summaryLine(mode: .vector, totals: vector))
            }

            var rasterOptions = PDFImportOptions()
            rasterOptions.diagnostics = Self.diagnosticSink(mode: "raster")
            // The `OMR_DECODE_*` sweep reaches this corpus the same way it
            // reaches the synthetic eval: by rewriting the manifest the
            // classifier reports, not the weights. Without it the corpus
            // cannot answer "is the glyph missing, or merely under τ?", which
            // is a different fix each way.
            rasterOptions.omrTileClassifier = try await Self.rasterClassifier()
            rasterOptions.omrRenderDPI = Self.doubleEnv("OMR_MSCZ_RENDER_DPI", default: 300)
            if Self.env("OMR_MSCZ_CENSUS") == "1" {
                for item in cases {
                    try MSCZGroundTruthSweep.glyphCensus(
                        item, scanDPI: scanDPI, options: rasterOptions,
                    )
                }
            }
            if Self.env("OMR_MSCZ_CLEF_CAPTURE") == "1" {
                for item in cases {
                    try MSCZGroundTruthSweep.clefCapture(
                        item, scanDPI: scanDPI, options: rasterOptions,
                    )
                }
            }
            if probesOnly {
                print("[mscz] probes only — score-level sweeps skipped (OMR_MSCZ_PROBES_ONLY=1)")
                return
            }
            let raster = MSCZGroundTruthSweep.sweep(
                cases: cases, mode: .raster, scanDPI: scanDPI, options: rasterOptions,
                dumpDivergence: dump,
            )
            print(MSCZGroundTruthSweep.summaryLine(mode: .raster, totals: raster))
        }

        /// The classifier the raster mode runs, with the `OMR_DECODE_*` sweep
        /// constants applied. `OMR_MODEL_ROOT` selects an exported model the
        /// same way it does for the synthetic eval; unset means the bundled
        /// one. The manifest's `checkpoint` is printed so the log itself says
        /// which weights produced its rows — a run that silently measured the
        /// bundled model under another model's name reported the two as
        /// byte-identical once, and nothing in the output said why.
        static func rasterClassifier() async throws -> OMRDecodeOverriddenClassifier {
            let base: CoreMLTileClassifier = if let modelPath = env("OMR_MODEL_ROOT") {
                try await CoreMLTileClassifier(
                    modelRoot: URL(fileURLWithPath: modelPath, isDirectory: true),
                )
            } else {
                // Synchronous: the bundled model is precompiled, and only
                // `init(modelRoot:)` compiles at run time.
                try CoreMLTileClassifier()
            }
            print("[mscz] model=\(env("OMR_MODEL_ROOT") ?? "bundled") "
                + "checkpoint=\(base.manifest.checkpoint)")
            return OMRDecodeOverriddenClassifier(base: base)
        }

        /// `nil` unless asked for: the sweep's own rows are the output, and a
        /// 657-score corpus emits enough diagnostics to bury them.
        static func diagnosticSink(mode: String) -> (@Sendable (PDFImportDiagnostic) -> Void)? {
            guard env("OMR_MSCZ_DIAGNOSTICS") == "1" else { return nil }
            return { diagnostic in
                print("[mscz-diag][\(mode)] \(diagnostic.location): \(diagnostic.message)"
                    + " | \(diagnostic.context ?? "")")
            }
        }

        /// The counterfactual, run on a REAL corpus document before either
        /// sweep: the same file, the same simulation, and NO classifier must
        /// fail outright.
        ///
        /// The wiring suite proves the simulation strips vector content from
        /// a synthetic rectangle. It cannot prove it for a MuseScore export,
        /// and that is the document whose numbers get quoted. Without this
        /// step a simulation that quietly left the page readable would
        /// publish the VECTOR front-end's score under the raster mode's name
        /// — the highest-value failure this harness could have, and one that
        /// looks like unusually good OMR rather than like a bug.
        @MainActor
        static func proveTheRasterPathIsLoadBearing(
            _ item: MSCZGroundTruthSweep.Case, scanDPI: Double,
        ) {
            var options = PDFImportOptions()
            options.diagnostics = nil
            let totals = MSCZGroundTruthSweep.sweep(
                cases: [item], mode: .raster, scanDPI: scanDPI, options: options,
            )
            print("[mscz-control] noClassifier scored=\(totals.scored) failed=\(totals.failed)")
            let complaint = "the simulated scan of \(item.name) was readable WITHOUT a "
                + "classifier, so the raster sweep's numbers are the vector front-end's"
            #expect(totals.scored == 0 && totals.failed == 1, Comment(rawValue: complaint))
        }
    }

    /// Ungated machinery tests. The harness above cannot run on a machine
    /// without the corpus, so without these the sweep's own logic — pairing,
    /// the per-file failure isolation, the scan simulation — would ship
    /// unexecuted, which is exactly the trap `reference_verification_traps`
    /// records as "the gate the plan wrote was empty".
    @MainActor
    struct MSCZGroundTruthSweepWiringTests {
        /// A two-page vector PDF, so the rasterized copy has something to
        /// lose if a page is dropped.
        static func vectorPDF(pages: Int) throws -> Data {
            let data = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 300, height: 200)
            // swiftlint:disable:next force_unwrapping
            let consumer = CGDataConsumer(data: data)!
            // swiftlint:disable:next force_unwrapping
            let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
            for _ in 0 ..< pages {
                context.beginPDFPage(nil)
                context.setFillColor(gray: 0, alpha: 1)
                context.fill(CGRect(x: 10, y: 10, width: 40, height: 20))
                context.endPDFPage()
            }
            context.closePDF()
            return data as Data
        }

        static func write(_ data: Data, to url: URL) throws {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            )
            try data.write(to: url)
        }

        @Test func theScanSimulationKeepsEveryPageAndDropsEveryVectorOperator() throws {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("mscz-sim-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let source = dir.appendingPathComponent("in.pdf")
            try Self.write(Self.vectorPDF(pages: 2), to: source)

            let scanned = try MSCZScanSimulator.imageOnlyPDF(of: source, dpi: 72)
            // swiftlint:disable:next force_unwrapping
            let document = CGPDFDocument(CGDataProvider(data: scanned as CFData)!)
            #expect(document?.numberOfPages == 2, "a page must not be lost to the simulation")

            // The point of the simulation: the vector walker has to come back
            // empty, or the raster fallback never runs and `mode: .raster`
            // silently measures the vector front-end instead.
            //
            // Asserted through the REFUSAL CODE, not merely "it threw". Both
            // documents throw here — neither carries a staff — so a bare
            // `#expect(throws:)` would pass just as happily on the untouched
            // vector PDF and prove nothing about the simulation.
            // `pdf.content.empty` is the only code that means "no glyphs and
            // no paths", which is the condition `applyRasterFallback` keys on.
            #expect(Self.refusalCode(of: scanned) == "pdf.content.empty")
            #expect(
                try Self.refusalCode(of: Self.vectorPDF(pages: 2)) == "pdf.staff.noneDetected",
                "the control: an untouched vector PDF refuses for a DIFFERENT reason",
            )
        }

        /// The `code` of the `ScoreFault` `PDFImporter.parse` refuses with,
        /// or nil when it did not refuse.
        static func refusalCode(of data: Data) -> String? {
            var options = PDFImportOptions()
            options.diagnostics = nil
            do {
                _ = try PDFImporter.parse(pdfData: data, options: options)
                return nil
            } catch let SheetMusicError.malformedScore(fault) {
                return fault.code
            } catch {
                return "\(error)"
            }
        }

        /// Pairing is by relative path, and a `.mscz` the prep script could
        /// not convert simply has no row — it must not pair with some other
        /// score's PDF, which is the failure that would silently compare two
        /// unrelated pieces of music.
        @Test func onlyMsczWithATwinPDFBecomeCases() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("mscz-pair-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let msczRoot = root.appendingPathComponent("src", isDirectory: true)
            let pdfRoot = root.appendingPathComponent("pdf", isDirectory: true)
            for name in ["a", "b", "nested/c"] {
                try Self.write(Data("x".utf8), to: msczRoot.appendingPathComponent("\(name).mscz"))
            }
            for name in ["a", "nested/c"] {
                try Self.write(Data("x".utf8), to: pdfRoot.appendingPathComponent("\(name).pdf"))
            }
            let cases = MSCZGroundTruthSweep.cases(msczRoot: msczRoot, pdfRoot: pdfRoot, limit: 0)
            #expect(cases.map(\.name) == ["a.mscz", "nested/c.mscz"])
        }

        /// `limit` takes a prefix of the SORTED pairing, so two runs at the
        /// same limit measure the same files.
        @Test func theLimitTakesAStablePrefix() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("mscz-limit-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let msczRoot = root.appendingPathComponent("src", isDirectory: true)
            let pdfRoot = root.appendingPathComponent("pdf", isDirectory: true)
            for name in ["c", "a", "b"] {
                try Self.write(Data("x".utf8), to: msczRoot.appendingPathComponent("\(name).mscz"))
                try Self.write(Data("x".utf8), to: pdfRoot.appendingPathComponent("\(name).pdf"))
            }
            let cases = MSCZGroundTruthSweep.cases(msczRoot: msczRoot, pdfRoot: pdfRoot, limit: 2)
            #expect(cases.map(\.name) == ["a.mscz", "b.mscz"])
        }

        /// One unreadable file costs its own row and nothing else. Without
        /// this the sweep's headline number would be the average over
        /// whatever happened to parse, with no trace of what did not.
        @Test func anUnreadableScoreIsCountedNotFatal() throws {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("mscz-fail-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let mscz = root.appendingPathComponent("broken.mscz")
            let pdf = root.appendingPathComponent("broken.pdf")
            try Self.write(Data("not a score".utf8), to: mscz)
            try Self.write(Self.vectorPDF(pages: 1), to: pdf)

            var options = PDFImportOptions()
            options.diagnostics = nil
            let totals = MSCZGroundTruthSweep.sweep(
                cases: [.init(mscz: mscz, pdf: pdf, name: "broken.mscz")],
                mode: .vector, scanDPI: 72, options: options,
            )
            #expect(totals.files == 1)
            #expect(totals.truthFailed == 1)
            #expect(totals.scored == 0)
        }

        /// An empty population prints `n/a`, never `0.0000`.
        @Test func anEmptySweepReportsNoScoreRatherThanZero() {
            let line = MSCZGroundTruthSweep.summaryLine(
                mode: .raster, totals: MSCZGroundTruthSweep.Totals(),
            )
            #expect(line.contains("pitchP50=n/a"))
            #expect(line.contains("durP50=n/a"))
        }
    }
#endif
