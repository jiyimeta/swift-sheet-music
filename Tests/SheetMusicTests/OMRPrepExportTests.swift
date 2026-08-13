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
        /// never as a silently-passing gate. `failed` is set only by a
        /// caller that catches a failure this function cannot recover
        /// from itself — either `exportPage`'s own throw for one page,
        /// or a directory-listing failure that keeps an entire render
        /// directory from being walked at all (this function never
        /// touches `failed` itself — see `OMRPrepExportHarness.sweep`,
        /// which catches both into the SAME counter and warns by name).
        struct Outcome: Equatable {
            var pages = 0
            var glyphs = 0
            var droppedNoBBox = 0
            var skippedNoStaff = 0
            var oversize = 0
            var failed = 0
        }

        /// `render.json` / `frozen.json`'s fields this stage needs,
        /// decoded tolerantly. A real render.json carries all three (see
        /// the task brief's worked example); a frozen eval directory
        /// (`Training/generate/build_dataset.py`) writes ONLY
        /// `frozen.json`, carrying `render_id` but never `face` or
        /// `provenance`; `OMRHarnessFixture`'s render.json carries
        /// neither. Nothing here may crash on any field's absence.
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
        /// PNG/JSON pair, and accumulate `totals`. Throws on any failure
        /// (bad labels, unreadable/corrupt raster, bad render.json) — a
        /// caller sweeping a whole dataset must catch this itself; see
        /// `OMRPrepExportHarness.sweep`, which does.
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

        /// `render_id` / `source_id` / `face`, read from `render.json`
        /// when present or `frozen.json` otherwise (Task 6 review,
        /// Critical: a frozen eval directory has no `render.json` at
        /// all, so unconditionally opening it threw on every frozen
        /// page). A missing `render_id` warns and falls back to the
        /// render directory's own basename regardless of which file it
        /// came from — both formats are documented to carry it. Missing
        /// `face` / `provenance.source_id` warns ONLY when the source
        /// was `render.json`: `frozen.json`'s schema never carries
        /// either (`build_dataset.py`), so their absence there is
        /// expected shape, not a real data gap, and does not warn.
        private static func renderMeta(
            dir: String,
        ) throws -> (renderId: String, sourceId: String, face: String) {
            let dirName = (dir as NSString).lastPathComponent
            let renderJSONPath = "\(dir)/render.json"
            let isFrozen = !FileManager.default.fileExists(atPath: renderJSONPath)
            let metaPath = isFrozen ? "\(dir)/frozen.json" : renderJSONPath
            let sourceFile = isFrozen ? "frozen.json" : "render.json"
            let decoded = try JSONDecoder().decode(
                RenderMeta.self, from: Data(contentsOf: URL(fileURLWithPath: metaPath)),
            )
            let renderId = decoded.renderId ?? warnFallback(
                dir: dirName, sourceFile: sourceFile, field: "render_id", value: dirName,
            )
            let face = decoded.face ?? (isFrozen ? "" : warnFallback(
                dir: dirName, sourceFile: sourceFile, field: "face", value: "",
            ))
            let sourceId = decoded.provenance?.sourceId ?? (isFrozen ? renderId : warnFallback(
                dir: dirName, sourceFile: sourceFile, field: "provenance.source_id",
                value: renderId,
            ))
            return (renderId: renderId, sourceId: sourceId, face: face)
        }

        /// Prints `[prep][WARN]` naming the directory, the source file,
        /// and the missing field, then returns `value` — the fallback
        /// used because the field genuinely should have been there.
        private static func warnFallback(
            dir: String, sourceFile: String, field: String, value: String,
        ) -> String {
            print("[prep][WARN] \(dir) \(sourceFile) missing \(field), using fallback")
            return value
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

            let result = try OMRPrepExportHarness.sweep(
                root: layout.root, prepRoot: prepRoot, staffSpacePx: 12, tile: 384,
            )
            // The fixture is a bare 5-line staff with no glyphs: a page
            // is exported, and zero glyph targets is the correct answer,
            // not a failure.
            #expect(result.totals.pages >= 1)
            #expect(result.totals.skippedNoStaff == 0)
            #expect(result.totals.failed == 0)
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
        /// root — what the byte-identical comparison needs. Shares the
        /// walk with `aWellFormedRenderProducesAPngAndAJsonSideBySide`
        /// via `OMRPrepExportHarness.sweep` rather than repeating it.
        private func exportAllAndHash(
            layout: OMRHarnessFixture.Layout, suffix: String,
        ) throws -> [String: Data] {
            let prepRoot = layout.root + suffix
            defer { try? FileManager.default.removeItem(atPath: prepRoot) }
            _ = try OMRPrepExportHarness.sweep(
                root: layout.root, prepRoot: prepRoot, staffSpacePx: 12, tile: 384,
            )
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
#endif
