#if !os(Android)
    import Foundation
    @testable import SheetMusicPDF
    import Testing

    /// Design §3.1 phase 1. No-op unless `OMR_PREP_EXPORT=1`.
    ///
    ///     OMR_DATA_ROOT=~/Datasets/sheet-music-omr/v2 \
    ///     OMR_PREP_ROOT=~/Datasets/sheet-music-omr/v2-prep \
    ///     ~/.claude/bin/run-with-memcap.sh 4000 /tmp/omr-prep.log \
    ///         env OMR_PREP_EXPORT=1 swift test -c release --no-parallel \
    ///         --filter OMRPrepExportHarness
    @Suite(.enabled(if: ProcessInfo.processInfo.environment["OMR_PREP_EXPORT"] == "1"))
    struct OMRPrepExportHarness {
        /// One dataset root's sweep: every render-OR-frozen directory
        /// (`OMRHarnessDirectoryWalk.renderOrFrozenDirectories`, so a
        /// prep root can be built for `eval_frozen/` too), every label
        /// file, exported through `OMRPrepExport.exportPage`. Not
        /// private, and factored out of the `@Test` below, so
        /// `OMRPrepExportFixtureTests` and `OMRPrepExportWiringTests`
        /// can drive the exact same walk the real dataset sweep uses
        /// (Task 6 review, Important 4) without needing the
        /// `OMR_PREP_EXPORT` gate on.
        ///
        /// A single page's failure — a corrupt raster, a bad labels
        /// file, a bad render.json — is caught, counted in
        /// `totals.failed`, and named in a printed `[prep][WARN]` line;
        /// it never aborts the walk. In a multi-hour real-dataset sweep
        /// the alternative is losing every count already gathered for
        /// one bad page, because the summary only prints after the loop
        /// completes (Task 6 review, Critical / Important 2).
        ///
        /// A directory-LISTING failure (a permission fault or an I/O
        /// fault on an external mount, a directory disappearing mid-walk)
        /// goes through the exact same `totals.failed` counter and
        /// `[prep][WARN]` line, one per unlistable directory — reusing
        /// `failed` rather than adding a second counter, since both are
        /// "the sweep could not process this" and the summary line
        /// already surfaces it (Task 6 review round 2, Important). The
        /// first cut of this fix used `try?` here, which swallowed the
        /// failure with no count and no line — exactly the silent-drop
        /// this counter exists to rule out.
        static func sweep(
            root: String, prepRoot: String, staffSpacePx: Double, tile: Int,
        ) throws -> (renders: Int, totals: OMRPrepExport.Outcome) {
            let renderDirs = try OMRHarnessDirectoryWalk.renderOrFrozenDirectories(root: root)
            var totals = OMRPrepExport.Outcome()
            for dir in renderDirs {
                autoreleasepool {
                    do {
                        for name in try OMRHarnessDirectoryWalk.labelFiles(in: dir) {
                            do {
                                try OMRPrepExport.exportPage(
                                    dir: dir, labelFile: name, prepRoot: prepRoot,
                                    staffSpacePx: staffSpacePx, tile: tile, into: &totals,
                                )
                            } catch {
                                totals.failed += 1
                                print("[prep][WARN] \(dir)/\(name) \(error)")
                            }
                        }
                    } catch {
                        totals.failed += 1
                        print("[prep][WARN] \(dir) \(error)")
                    }
                }
            }
            return (renders: renderDirs.count, totals: totals)
        }

        @Test func exportEveryRender() throws {
            guard let root = ProcessInfo.processInfo.environment["OMR_DATA_ROOT"] else {
                Issue.record("OMR_PREP_EXPORT=1 but OMR_DATA_ROOT is unset")
                return
            }
            guard let prepRoot = ProcessInfo.processInfo.environment["OMR_PREP_ROOT"] else {
                Issue.record("OMR_PREP_EXPORT=1 but OMR_PREP_ROOT is unset")
                return
            }
            let staffSpacePx = ProcessInfo.processInfo.environment["OMR_PREP_STAFF_SPACE_PX"]
                .flatMap(Double.init) ?? 12
            let tile = ProcessInfo.processInfo.environment["OMR_PREP_TILE"]
                .flatMap(Int.init) ?? 384

            let result = try Self.sweep(
                root: root, prepRoot: prepRoot, staffSpacePx: staffSpacePx, tile: tile,
            )
            let totals = result.totals
            print(
                "[prep][SUMMARY] renders=\(result.renders) pages=\(totals.pages) "
                    + "glyphs=\(totals.glyphs) dropped_no_bbox=\(totals.droppedNoBBox) "
                    + "skipped_no_staff=\(totals.skippedNoStaff) oversize=\(totals.oversize) "
                    + "failed=\(totals.failed) peakRSS=\(OMRPageBitmapLoader.peakResidentMB())MB",
            )
        }
    }

    /// Ungated wiring tests for `OMRPrepExportHarness.sweep` and
    /// `OMRPrepExport`'s corners that `OMRHarnessFixture` cannot exercise
    /// (it carries only vector PDF content, zero glyphs, and no
    /// `frozen.json`) — added per Task 6 review (Critical, Important 1
    /// and 2). Builds its own minimal directories rather than reusing
    /// `OMRHarnessFixture`, so no `@MainActor` is needed here.
    struct OMRPrepExportWiringTests {
        @Test func aFrozenDirectoryIsWalkedAndExported() throws {
            let root = try makeTempRoot()
            defer { try? FileManager.default.removeItem(atPath: root) }
            try PrepFixture.stage(
                at: "\(root)/frozen_0001", markerName: "frozen.json",
                markerJSON: ["render_id": "frozen_0001"],
                labels: PrepFixture.labels(glyphs: []), raster: PrepFixture.staffBitmap(),
            )
            let prepRoot = root + "-prep"
            defer { try? FileManager.default.removeItem(atPath: prepRoot) }

            let result = try OMRPrepExportHarness.sweep(
                root: root, prepRoot: prepRoot, staffSpacePx: 12, tile: 384,
            )
            #expect(result.renders == 1)
            #expect(result.totals.pages == 1)
            #expect(result.totals.failed == 0)
            let files = try FileManager.default.subpathsOfDirectory(atPath: prepRoot)
            #expect(files.contains { $0.hasSuffix(".prep.png") })
        }

        @Test func oversizeCountsAGlyphWhoseAdvanceExceedsTheTile() throws {
            let root = try makeTempRoot()
            defer { try? FileManager.default.removeItem(atPath: root) }
            let dir = "\(root)/render_0001"
            // `advancePx`/`renderedSizePx` are derived from the MAPPED
            // bbox corners, not from `advancePt`/`renderedSizePt`
            // directly (final-review-fixes.md finding #4 — the old
            // shortcut bypassed the label homography and drifted on a
            // degraded page). So an oversized EXPORTED glyph needs an
            // oversized BBOX; a huge `advancePt` paired with a tiny bbox
            // (this test's old fixture) no longer produces an oversized
            // `advancePx` at all — 200pt wide, well past the 384px tile
            // at this fixture's ~1:1 clean-page scale (300dpi, staff
            // detected at ~16px, normalized to `staffSpacePx: 16`).
            let glyph = OMRPageLabels.Glyph(
                className: "noteheadBlack", bboxPt: [10, 10, 210, 20], originPt: [15, 15],
                advancePt: 12, renderedSizePt: 8, fontSizePt: 0,
            )
            try PrepFixture.stage(
                at: dir, markerName: "render.json",
                markerJSON: ["pdf": "score.pdf", "dpi": 300],
                labels: PrepFixture.labels(glyphs: [glyph]), raster: PrepFixture.staffBitmap(),
            )
            let prepRoot = root + "-prep"
            defer { try? FileManager.default.removeItem(atPath: prepRoot) }

            var totals = OMRPrepExport.Outcome()
            try OMRPrepExport.exportPage(
                dir: dir, labelFile: "page_0.labels.json", prepRoot: prepRoot,
                staffSpacePx: 16, tile: 384, into: &totals,
            )
            #expect(totals.glyphs == 1)
            #expect(totals.oversize == 1)
        }

        /// "aaa_broken" sorts before "bbb_good" so the walk hits the
        /// failure first — proving a failed page does not stop later
        /// renders from being processed and counted.
        @Test func aFailedPageIsCountedAndDoesNotStopTheWalk() throws {
            let root = try makeTempRoot()
            defer { try? FileManager.default.removeItem(atPath: root) }
            try PrepFixture.stage(
                at: "\(root)/aaa_broken", markerName: "render.json",
                markerJSON: ["pdf": "score.pdf", "dpi": 300],
                labels: PrepFixture.labels(glyphs: []), raster: nil,
            )
            try PrepFixture.stage(
                at: "\(root)/bbb_good", markerName: "render.json",
                markerJSON: ["pdf": "score.pdf", "dpi": 300],
                labels: PrepFixture.labels(glyphs: []), raster: PrepFixture.staffBitmap(),
            )
            let prepRoot = root + "-prep"
            defer { try? FileManager.default.removeItem(atPath: prepRoot) }

            let result = try OMRPrepExportHarness.sweep(
                root: root, prepRoot: prepRoot, staffSpacePx: 12, tile: 384,
            )
            #expect(result.renders == 2)
            #expect(result.totals.failed == 1)
            #expect(result.totals.pages == 1)
        }

        /// A directory-listing failure (permission fault, I/O fault on
        /// an external mount, directory vanishing mid-walk) must be
        /// counted and warned about, not silently dropped from the
        /// sweep (Task 6 review round 2). Reproduced portably with a
        /// POSIX permission split rather than anything Android/Linux
        /// wouldn't share the exact bits of — this file is already
        /// `#if !os(Android)`-gated, so that is not a constraint here:
        /// `chmod 0111` (execute-only, no read) leaves `stat`-by-known-
        /// name working — so `renderOrFrozenDirectories`'s
        /// `fileExists(atPath: "<dir>/render.json")` still finds the
        /// directory and includes it in the walk — while `readdir`
        /// (what `labelFiles(in:)`'s `contentsOfDirectory` needs) is
        /// denied. "aaa_unlistable" sorts before "bbb_good" so the walk
        /// hits the failure first, proving it does not stop the rest of
        /// the sweep.
        @Test func anUnlistableDirectoryIsCountedAndDoesNotStopTheWalk() throws {
            let root = try makeTempRoot()
            let unlistableDir = "\(root)/aaa_unlistable"
            defer {
                // Recursive cleanup needs to read `unlistableDir` to
                // delete its contents, so undo the restriction first.
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755], ofItemAtPath: unlistableDir,
                )
                try? FileManager.default.removeItem(atPath: root)
            }
            try PrepFixture.stage(
                at: unlistableDir, markerName: "render.json",
                markerJSON: ["pdf": "score.pdf", "dpi": 300],
                labels: PrepFixture.labels(glyphs: []), raster: PrepFixture.staffBitmap(),
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o111], ofItemAtPath: unlistableDir,
            )
            try PrepFixture.stage(
                at: "\(root)/bbb_good", markerName: "render.json",
                markerJSON: ["pdf": "score.pdf", "dpi": 300],
                labels: PrepFixture.labels(glyphs: []), raster: PrepFixture.staffBitmap(),
            )
            let prepRoot = root + "-prep"
            defer { try? FileManager.default.removeItem(atPath: prepRoot) }

            let result = try OMRPrepExportHarness.sweep(
                root: root, prepRoot: prepRoot, staffSpacePx: 12, tile: 384,
            )
            #expect(result.renders == 2)
            #expect(result.totals.failed == 1)
            #expect(result.totals.pages == 1)
        }

        private func makeTempRoot() throws -> String {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("omr-prep-wiring-\(UUID().uuidString)").path
            try FileManager.default.createDirectory(
                atPath: root, withIntermediateDirectories: true,
            )
            return root
        }
    }

    /// Minimal, `OMRHarnessFixture`-independent directory builders for
    /// `OMRPrepExportWiringTests`: a marker file (`render.json` or
    /// `frozen.json`), one label file, and an optional raster (`nil`
    /// leaves `page.image.file` unwritten — the corrupt/missing-page
    /// case).
    private enum PrepFixture {
        static func labels(
            glyphs: [OMRPageLabels.Glyph], widthPt: Double = 200, heightPt: Double = 100,
            dpi: Int = 300,
        ) -> OMRPageLabels {
            OMRPageLabels(
                schema: 1,
                page: OMRPageLabels.Page(index: 0, widthPt: widthPt, heightPt: heightPt),
                image: OMRPageLabels.Image(
                    file: "page_0.png", dpi: dpi,
                    labelTransform: [1, 0, 0, 0, 1, 0, 0, 0, 1], sourceSizePx: nil,
                ),
                glyphs: glyphs, paths: [], beams: [], curves: [], texts: [],
                census: OMRPageLabels.Census(glyphsByClass: [:], texts: 0),
            )
        }

        static func staffBitmap() -> GrayBitmap {
            RasterTestBitmaps.staff(
                widthPx: 600, heightPx: 400, dpi: 300, topY: 100, spacingPx: 16,
            )
        }

        static func stage(
            at dir: String, markerName: String, markerJSON: [String: Any],
            labels: OMRPageLabels, raster: GrayBitmap?,
        ) throws {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true,
            )
            try JSONSerialization.data(withJSONObject: markerJSON)
                .write(to: URL(fileURLWithPath: "\(dir)/\(markerName)"))
            try OMRLabelSchema.encodeCanonical(labels)
                .write(to: URL(fileURLWithPath: "\(dir)/page_0.labels.json"))
            if let raster {
                try OMRPrepPNG.write(
                    raster, to: URL(fileURLWithPath: "\(dir)/\(labels.image.file)"),
                )
            }
        }
    }
#endif
