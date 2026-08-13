#if !os(Android)
    import Foundation
    @testable import SheetMusicPDF
    import Testing

    /// The prep export harness (design §3.1 phase 1): per page, load the
    /// rendered raster, deskew + rescale it to the detector's canonical
    /// staff space, project the ground-truth labels into the same frame,
    /// and write the PNG/JSON pair a training run consumes.
    ///
    /// Composes Tasks 1/3/4/5 rather than reimplementing any of them —
    /// preprocessing has exactly ONE implementation, here, because a
    /// second one (in Python) drifting from this one would not crash; it
    /// would just make the detector quietly worse.
    enum OMRPrepExport {
        /// Batch counters. Every summary line built on top of this leads
        /// with a count, so an empty traversal reads as "zero renders",
        /// never as a silently-passing gate.
        struct Outcome: Equatable {
            var pages = 0
            var glyphs = 0
            var droppedNoBBox = 0
            var skippedNoStaff = 0
            var oversize = 0
        }

        /// `render.json`'s fields this stage needs, decoded tolerantly.
        /// `OMRHarnessFixture` writes only `pdf` and `dpi` — no
        /// `render_id`, `face`, or `provenance` — while a real dataset's
        /// render.json carries all three (see the task brief's worked
        /// example). Nothing here may crash on their absence.
        private struct RenderMeta: Decodable {
            var renderId: String?
            var face: String?
            var provenance: Provenance?

            struct Provenance: Decodable {
                var sourceId: String?
                enum CodingKeys: String, CodingKey {
                    case sourceId = "source_id"
                }
            }

            enum CodingKeys: String, CodingKey {
                case renderId = "render_id"
                case face
                case provenance
            }
        }

        /// One page: decode labels, load + analyze the raster, bail out
        /// when there is no staff to measure the canonical scale by,
        /// normalize, project labels to detector targets, write the
        /// PNG/JSON pair, and accumulate `totals`.
        static func exportPage(
            dir: String, labelFile: String, prepRoot: String,
            staffSpacePx: Double, tile: Int, into totals: inout Outcome,
        ) throws {
            let page = try OMRLabelSchema.decode(
                Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(labelFile)")),
            )
            let imageURL = URL(fileURLWithPath: "\(dir)/\(page.image.file)")
            let analysis = try OMRPageBitmapLoader.withPageBitmap(
                url: imageURL, dpi: Double(page.image.dpi),
            ) { RasterPage.analyze($0, pageIndex: page.page.index, keepDeskewed: true) }
            guard analysis.staffSpacingPx > 0, let deskewed = analysis.deskewed else {
                totals.skippedNoStaff += 1
                return
            }
            guard let normalized = OMRPrepNormalize.normalize(
                deskewed, staffSpacingPx: analysis.staffSpacingPx,
                targetStaffSpacePx: staffSpacePx,
            ) else {
                totals.skippedNoStaff += 1
                return
            }
            let (glyphs, droppedNoBBox) = OMRPrepTargets.glyphs(
                page: page, transform: analysis.transform, scale: normalized.scale,
            )
            let oversize = glyphs.count {
                $0.advancePx > Double(tile) || $0.renderedSizePx > Double(tile)
            }
            let meta = try renderMeta(dir: dir)
            try writePreppedPage(
                normalized: normalized, glyphs: glyphs, pageIndex: page.page.index,
                meta: meta, prepRoot: prepRoot, staffSpacePx: staffSpacePx,
                deskewed: deskewed, deskewDegrees: analysis.deskewDegrees,
            )
            totals.pages += 1
            totals.glyphs += glyphs.count
            totals.droppedNoBBox += droppedNoBBox
            totals.oversize += oversize
        }

        /// `render_id` / `source_id` / `face`, falling back to the render
        /// directory's own basename (and to `render_id` again for
        /// `source_id`) when `render.json` omits them.
        private static func renderMeta(
            dir: String,
        ) throws -> (renderId: String, sourceId: String, face: String) {
            let dirName = (dir as NSString).lastPathComponent
            let data = try Data(contentsOf: URL(fileURLWithPath: "\(dir)/render.json"))
            let decoded = try JSONDecoder().decode(RenderMeta.self, from: data)
            let renderId = decoded.renderId ?? dirName
            return (
                renderId: renderId,
                sourceId: decoded.provenance?.sourceId ?? renderId,
                face: decoded.face ?? "",
            )
        }

        /// Writes `<prepRoot>/<render_id>/page_<n>.prep.{png,json}`,
        /// creating `<prepRoot>/<render_id>/` as needed.
        private static func writePreppedPage(
            normalized: OMRPrepNormalize.Result, glyphs: [OMRPrepPage.Glyph], pageIndex: Int,
            meta: (renderId: String, sourceId: String, face: String), prepRoot: String,
            staffSpacePx: Double, deskewed: GrayBitmap, deskewDegrees: Double,
        ) throws {
            let outDir = URL(fileURLWithPath: prepRoot).appendingPathComponent(meta.renderId)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
            let stem = "page_\(pageIndex)"
            let pngName = "\(stem).prep.png"
            try OMRPrepPNG.write(normalized.bitmap, to: outDir.appendingPathComponent(pngName))
            let prepPage = OMRPrepPage(
                schema: OMRPrepSchema.version,
                renderId: meta.renderId, sourceId: meta.sourceId, face: meta.face,
                pageIndex: pageIndex,
                image: OMRPrepPage.Image(
                    file: pngName,
                    widthPx: normalized.bitmap.width, heightPx: normalized.bitmap.height,
                    staffSpacePx: staffSpacePx, scale: normalized.scale,
                    sourceWidthPx: deskewed.width, sourceHeightPx: deskewed.height,
                    sourceDpi: deskewed.dpi, deskewDegrees: deskewDegrees,
                ),
                glyphs: glyphs,
            )
            try OMRPrepSchema.encodeCanonical(prepPage)
                .write(to: outDir.appendingPathComponent("\(stem).prep.json"))
        }
    }

    @MainActor struct OMRPrepExportFixtureTests {
        @Test func aWellFormedRenderProducesAPngAndAJsonSideBySide() throws {
            let layout = try OMRHarnessFixture.makeLayout()
            defer { OMRHarnessFixture.cleanup(layout) }
            try stagePageImages(layout: layout)
            let prepRoot = layout.root + "-prep"
            defer { try? FileManager.default.removeItem(atPath: prepRoot) }

            var totals = OMRPrepExport.Outcome()
            for dir in try OMRHarnessDirectoryWalk.renderDirectories(root: layout.root) {
                for name in try OMRHarnessDirectoryWalk.labelFiles(in: dir) {
                    try OMRPrepExport.exportPage(
                        dir: dir, labelFile: name, prepRoot: prepRoot,
                        staffSpacePx: 12, tile: 384, into: &totals,
                    )
                }
            }
            // The fixture is a bare 5-line staff with no glyphs: a page
            // is exported, and zero glyph targets is the correct answer,
            // not a failure.
            #expect(totals.pages >= 1)
            #expect(totals.skippedNoStaff == 0)
            let files = try FileManager.default.subpathsOfDirectory(atPath: prepRoot)
            #expect(files.contains { $0.hasSuffix(".prep.png") })
            #expect(files.contains { $0.hasSuffix(".prep.json") })
        }

        @Test func exportingTwiceIsByteIdentical() throws {
            // Gate P3d-G4 in miniature. The full-dataset run is Task 13;
            // this is the version that runs on every `swift test`.
            let layout = try OMRHarnessFixture.makeLayout()
            defer { OMRHarnessFixture.cleanup(layout) }
            try stagePageImages(layout: layout)
            let a = try exportAllAndHash(layout: layout, suffix: "-prep-a")
            let b = try exportAllAndHash(layout: layout, suffix: "-prep-b")
            #expect(a == b)
            #expect(!a.isEmpty)
        }

        /// `OMRHarnessFixture` derives every render directory's labels
        /// from a vector PDF and never rasterizes it — the wiring tests
        /// that already consume this fixture work from the PDF directly.
        /// This export reads a raster PNG named by `page.image.file`, so
        /// this suite supplies one itself: a synthetic 5-line staff sized
        /// for `RasterPage.analyze` to detect. Written into both
        /// `wellFormedDir` and `missingSourceDir` — the two directories
        /// whose `page_0.labels.json` names `page_0.png` — never into
        /// `missingLabelsDir`, whose label file this suite never reads.
        private func stagePageImages(layout: OMRHarnessFixture.Layout) throws {
            let bitmap = RasterTestBitmaps.staff(
                widthPx: 600, heightPx: 400, dpi: Double(OMRHarnessFixture.dpi),
                topY: 100, spacingPx: 16,
            )
            for dir in [layout.wellFormedDir, layout.missingSourceDir] {
                try OMRPrepPNG.write(bitmap, to: URL(fileURLWithPath: "\(dir)/page_0.png"))
            }
        }

        /// Runs the export into `layout.root + suffix` and returns every
        /// produced file's bytes, keyed by path relative to the prep
        /// root — what the byte-identical comparison needs.
        private func exportAllAndHash(
            layout: OMRHarnessFixture.Layout, suffix: String,
        ) throws -> [String: Data] {
            let prepRoot = layout.root + suffix
            defer { try? FileManager.default.removeItem(atPath: prepRoot) }
            var totals = OMRPrepExport.Outcome()
            for dir in try OMRHarnessDirectoryWalk.renderDirectories(root: layout.root) {
                for name in try OMRHarnessDirectoryWalk.labelFiles(in: dir) {
                    try OMRPrepExport.exportPage(
                        dir: dir, labelFile: name, prepRoot: prepRoot,
                        staffSpacePx: 12, tile: 384, into: &totals,
                    )
                }
            }
            var out: [String: Data] = [:]
            for relative in try FileManager.default.subpathsOfDirectory(atPath: prepRoot) {
                let full = "\(prepRoot)/\(relative)"
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: full, isDirectory: &isDirectory),
                      !isDirectory.boolValue
                else { continue }
                out[relative] = try Data(contentsOf: URL(fileURLWithPath: full))
            }
            return out
        }
    }

    /// Design §3.1 phase 1. No-op unless `OMR_PREP_EXPORT=1`.
    ///
    ///     OMR_DATA_ROOT=~/Datasets/sheet-music-omr/v2 \
    ///     OMR_PREP_ROOT=~/Datasets/sheet-music-omr/v2-prep \
    ///     ~/.claude/bin/run-with-memcap.sh 4000 /tmp/omr-prep.log \
    ///         env OMR_PREP_EXPORT=1 swift test -c release --no-parallel \
    ///         --filter OMRPrepExportHarness
    @Suite(.enabled(if: ProcessInfo.processInfo.environment["OMR_PREP_EXPORT"] == "1"))
    struct OMRPrepExportHarness {
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

            let renderDirs = try OMRHarnessDirectoryWalk.renderOrFrozenDirectories(root: root)
            var totals = OMRPrepExport.Outcome()
            for dir in renderDirs {
                try autoreleasepool {
                    for name in try OMRHarnessDirectoryWalk.labelFiles(in: dir) {
                        try OMRPrepExport.exportPage(
                            dir: dir, labelFile: name, prepRoot: prepRoot,
                            staffSpacePx: staffSpacePx, tile: tile, into: &totals,
                        )
                    }
                }
            }
            print(
                "[prep][SUMMARY] renders=\(renderDirs.count) pages=\(totals.pages) "
                    + "glyphs=\(totals.glyphs) dropped_no_bbox=\(totals.droppedNoBBox) "
                    + "skipped_no_staff=\(totals.skippedNoStaff) oversize=\(totals.oversize) "
                    + "peakRSS=\(OMRPageBitmapLoader.peakResidentMB())MB",
            )
        }
    }
#endif
