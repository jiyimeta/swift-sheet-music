#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    /// TEMPORARY diagnostic — the hybrid sweep reports perfect measure
    /// and note counts with perfect durations but 5% pitch, so the staff
    /// geometry is what to look at. Prints the oracle's detected staves
    /// against the raster's, per page.
    @Suite(.enabled(if: ProcessInfo.processInfo.environment["OMR_STAFF_PROBE"] == "1"))
    struct RasterStaffProbeHarness {
        /// Horizontal segments as `y×width` pairs, widest first, so an
        /// invented staff can be traced back to the ink that produced it.
        func printLines(_ tag: String, _ pairs: [(Double, Double)]) {
            let wide = pairs.filter { $0.1 > 40 }.sorted { $0.0 > $1.0 }
            let text = wide.map {
                "\(Int($0.0.rounded()))x\(Int($0.1.rounded()))"
            }.joined(separator: " ")
            print("[probe]   \(tag) n=\(wide.count) \(text)")
        }

        @Test func compareDetectedStaves() throws {
            guard let root = ProcessInfo.processInfo.environment["OMR_DATA_ROOT"] else {
                return
            }
            for dir in try OMRHarnessDirectoryWalk.renderDirectories(root: root).prefix(3) {
                for name in try OMRHarnessDirectoryWalk.labelFiles(in: dir).prefix(1) {
                    let page = try OMRLabelSchema.decode(
                        Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(name)")),
                    )
                    let replay = try OMROracleFrontEnd.replay(pages: [page])
                    let idx = page.page.index
                    let oracle = PDFImporter.detectStaves(
                        paths: replay.walked.paths.filter { $0.pageIndex == idx },
                        classified: replay.walked.glyphs.filter { $0.geometry.pageIndex == idx },
                        pageIndex: idx,
                    )
                    let url = URL(fileURLWithPath: "\(dir)/\(page.image.file)")
                    let analysis = try OMRPageBitmapLoader.withPageBitmap(
                        url: url, dpi: Double(page.image.dpi),
                    ) { RasterPage.analyze($0, pageIndex: idx) }
                    let raster = PDFImporter.detectStaves(
                        paths: analysis.paths,
                        classified: replay.walked.glyphs.filter { $0.geometry.pageIndex == idx },
                        pageIndex: idx,
                    )
                    let tag = (dir as NSString).lastPathComponent
                    print(
                        "[probe] \(tag) spacingPt=\(analysis.staffSpacingPt) "
                            + "oracleStaves=\(oracle.count) rasterStaves=\(raster.count) "
                            + "horiz=\(analysis.paths.count(where: { $0.kind == .horizontal })) "
                            + "vert=\(analysis.paths.count(where: { $0.kind == .vertical }))",
                    )
                    for (i, staff) in oracle.enumerated() {
                        print("[probe]   oracle[\(i)] yLines=\(staff.yLines.map { round($0 * 10) / 10 })")
                    }
                    for (i, staff) in raster.enumerated() {
                        print("[probe]   raster[\(i)] yLines=\(staff.yLines.map { round($0 * 10) / 10 })")
                    }
                    if ProcessInfo.processInfo.environment["OMR_STAFF_PROBE_LINES"] == "1" {
                        let truth = replay.walked.paths.filter {
                            $0.pageIndex == idx && $0.kind == .horizontal
                        }
                        printLines("oracleH", truth.map {
                            (Double($0.rect.midY), Double($0.rect.width))
                        })
                        printLines(
                            "rasterH",
                            analysis.paths.filter { $0.kind == .horizontal }
                                .map { (Double($0.rect.midY), Double($0.rect.width)) },
                        )
                    }
                }
            }
        }
    }
#endif
