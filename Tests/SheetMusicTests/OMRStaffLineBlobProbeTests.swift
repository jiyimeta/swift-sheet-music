#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    /// The row-width profile behind ONE staff line, on the pages the
    /// corpus probes have already named.
    ///
    /// `[sldiag]` prices the staff-line seam over 69 pages and reports
    /// where it costs something; it cannot say why a particular line
    /// landed where it did, because the only evidence for that is the
    /// blob's `rowWidths` and the `PathSegment` it turns into keeps none
    /// of them. This suite takes a short list of `render|labelFile|yPt`
    /// targets and dumps, for each, every emitted blob within a band of
    /// that y: its box, its centre row, its per-row inked width, and the
    /// truth horizontals at the same y for comparison.
    ///
    /// Targets rather than a sweep on purpose. Two pages of profiles is a
    /// readable page of output; 69 is a file nobody reads, and the corpus
    /// probes already say which two pages to look at.
    ///
    ///     OMR_SLBLOB=1 OMR_DATA_ROOT=~/Datasets/sheet-music-omr/v2-eval \
    ///     OMR_SLBLOB_TARGETS='tex_0009_ms4_Petaluma_v9|page_0.labels.json|300' \
    ///     swift test -c release --no-parallel --filter OMRStaffLineBlobProbe
    @Suite(.enabled(if: ProcessInfo.processInfo.environment["OMR_SLBLOB"] == "1"))
    struct OMRStaffLineBlobProbe {
        struct Target {
            var render: String
            var labelFile: String
            var yPt: Double
        }

        /// How far from the target y a blob is still printed, in staff
        /// spaces. 14 covers a five-line staff (8 spaces) with room on
        /// both sides for the neighbour a merge could have reached into.
        static var bandInSpaces: Double {
            ProcessInfo.processInfo.environment["OMR_SLBLOB_BAND"]
                .flatMap(Double.init) ?? 14.0
        }

        static func targets() -> [Target] {
            let raw = ProcessInfo.processInfo.environment["OMR_SLBLOB_TARGETS"] ?? ""
            return raw.split(separator: ",").compactMap { entry in
                let parts = entry.split(separator: "|", omittingEmptySubsequences: false)
                guard parts.count == 3, let y = Double(parts[2]) else { return nil }
                return Target(
                    render: String(parts[0]), labelFile: String(parts[1]), yPt: y,
                )
            }
        }

        @Test func blobProfilesAtTargets() throws {
            guard let root = ProcessInfo.processInfo.environment["OMR_DATA_ROOT"] else {
                Issue.record("OMR_SLBLOB=1 but OMR_DATA_ROOT is unset")
                return
            }
            let wanted = Self.targets()
            guard !wanted.isEmpty else {
                Issue.record("OMR_SLBLOB=1 but OMR_SLBLOB_TARGETS names no target")
                return
            }
            for dir in try OMRHarnessDirectoryWalk.renderOrFrozenDirectories(root: root) {
                let name = URL(fileURLWithPath: dir).lastPathComponent
                for target in wanted where target.render == name {
                    try dump(target, dir: dir)
                }
            }
        }

        func dump(_ target: Target, dir: String) throws {
            let page = try OMRLabelSchema.decode(
                Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(target.labelFile)")),
            )
            let imageURL = URL(fileURLWithPath: "\(dir)/\(page.image.file)")
            guard FileManager.default.fileExists(atPath: imageURL.path) else { return }
            let profiles = try OMRPageBitmapLoader.withPageBitmap(
                url: imageURL, dpi: Double(page.image.dpi),
            ) { bitmap -> [String] in
                let analysis = RasterPage.analyze(
                    bitmap, pageIndex: page.page.index, keepDeskewed: true,
                )
                guard let straight = analysis.deskewed else { return [] }
                let mask = RasterPage.binarize(straight)
                guard let spacingPx = RasterPage.estimateStaffSpacingPx(mask) else { return [] }
                return Self.rows(
                    RasterPage.staffLineBlobProfiles(
                        mask, spacingPx: spacingPx, transform: analysis.transform,
                        pageIndex: page.page.index,
                    ),
                    target: target, spacingPt: analysis.staffSpacingPt,
                )
            }
            let prefix = "[slblob] render=\(target.render) file=\(target.labelFile) "
                + "y=\(String(format: "%.1f", target.yPt))"
            for row in profiles {
                print(prefix + " " + row)
            }
            for row in Self.truthRows(page, target: target) {
                print(prefix + " " + row)
            }
        }

        /// One line per emitted blob in the band, widest-row-relative so
        /// the shape reads at a glance: `*` marks the widest row, `+` a
        /// row at least `staffLineCoreRowWidthFraction` of it (the rows
        /// `centerRow` averages) and `.` a row it disowned.
        static func rows(
            _ profiles: [RasterPage.BlobProfile], target: Target, spacingPt: Double,
        ) -> [String] {
            let band = Self.bandInSpaces * max(spacingPt, 1)
            return profiles
                .filter { abs(Double($0.segment.rect.midY) - target.yPt) <= band }
                .sorted { $0.segment.rect.midY < $1.segment.rect.midY }
                .map { p in
                    let widest = p.rowWidths.max() ?? 0
                    let floor = Double(widest) * RasterPage.staffLineCoreRowWidthFraction
                    let shape = p.rowWidths.map { w -> String in
                        let mark = w == widest ? "*" : (Double(w) >= floor ? "+" : ".")
                        return "\(mark)\(w)"
                    }.joined(separator: " ")
                    return "blob yPt=" + String(format: "%.2f", Double(p.segment.rect.midY))
                        + " x0=" + String(format: "%.1f", Double(p.segment.rect.minX))
                        + " x1=" + String(format: "%.1f", Double(p.segment.rect.maxX))
                        + " w=" + String(format: "%.1f", Double(p.segment.rect.width))
                        + " rows=\(p.yTop)...\(p.yBottom)"
                        + " centerRow=" + String(format: "%.2f", p.centerRow)
                        + " boxMid=" + String(format: "%.2f", Double(p.yTop + p.yBottom) / 2)
                        + " widths=[" + shape + "]"
                }
        }

        /// The truth horizontals in the same band, so an over-long blob
        /// is visible as an over-long blob rather than as a number.
        static func truthRows(_ page: OMRPageLabels, target: Target) -> [String] {
            let band = Self.bandInSpaces * 4.56
            return page.paths
                .filter {
                    $0.kind == "horizontal" && abs($0.rectPt[1] - target.yPt) <= band
                }
                .sorted { ($0.rectPt[1], $0.rectPt[0]) < ($1.rectPt[1], $1.rectPt[0]) }
                .map { p in
                    "truth yPt=" + String(format: "%.2f", p.rectPt[1])
                        + " x0=" + String(format: "%.1f", p.rectPt[0])
                        + " x1=" + String(format: "%.1f", p.rectPt[2])
                        + " w=" + String(format: "%.1f", p.rectPt[2] - p.rectPt[0])
                        + " lw=" + String(format: "%.2f", p.lineWidthPt)
                }
        }
    }
#endif
