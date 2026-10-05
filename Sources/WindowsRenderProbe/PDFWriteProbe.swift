import Foundation
import SheetMusicBridgeCore
import SheetMusicPDFWriter
import SheetMusicRenderWindows

/// `windows-render-probe --write-pdf <score> <out dir>`: a real score laid out on A4 in page mode, written by
/// `ScorePDFWriter`, and the PDF drawn back by Windows' own PDF engine (`ScorePDF`) beside the same pages drawn
/// straight by Direct2D (`Direct2DPageRenderer`) — the PDF writer's check against the renderer it follows (folino's
/// P4c plan, Task 5). Writes `score.pdf` and, for the first pages, `page-<n>-direct2d.png` and `page-<n>-pdf.png`, and
/// prints how much ink each has and how much of it the other lacks.
///
/// The two rasterizers antialias differently, so the comparison is of ink, not pixels: a dark pixel (every channel
/// under 128) counts as missing from the other when no pixel within one of it is dark there. A glyph drawn in the wrong
/// face, at the wrong size or in the wrong place shows as a few percent missing; antialiasing alone stays well under
/// one. Exits 1 when either side is missing more than 2 % of the other's ink.
struct PDFWriteProbe {
    let scorePath: String
    let outputDirectory: URL
    private static let pxPerMM = 6.0

    func run() throws -> Bool {
        try installWindowsFontMetrics()
        let score = try ScoreBridge.loadScore(bytes: Data(contentsOf: URL(fileURLWithPath: scorePath)))
        let pages = ScorePages.compute(
            score: score, pageWidthMM: 210, pageHeightMM: 297, options: ScorePageOptions(mode: .page),
        )
        let fontFiles = ScoreSurface.bundledFontFiles
        func font(_ name: String) throws -> Data {
            guard let path = fontFiles.first(where: { $0.hasSuffix(name) }) else { throw ProbeError("no \(name)") }
            return try Data(contentsOf: URL(fileURLWithPath: path))
        }
        let fonts = try ScorePDFFonts(
            smufl: font("Bravura.otf"), roman: font("Edwin-Roman.otf"), bold: font("Edwin-Bold.otf"),
            italic: font("Edwin-Italic.otf"), boldItalic: font("Edwin-BdIta.otf"),
        )
        let clock = ContinuousClock()
        let start = clock.now
        let data = try ScorePDFWriter.write(pages, fonts: fonts, title: "probe")
        let writeMs = OnscreenSession.milliseconds(clock.now - start)
        let pdfURL = outputDirectory.appendingPathComponent("score.pdf")
        try data.write(to: pdfURL)
        print("wrote \(pages.pageCount) pages, \(data.count) bytes in \(String(format: "%.1f", writeMs)) ms")

        let pdf = try ScorePDF(path: pdfURL.path)
        var passed = pdf.pageCount == pages.pageCount
        print("Windows reads \(pdf.pageCount) pages")
        for page in 0 ..< min(2, pages.pageCount) {
            let prefix = outputDirectory.appendingPathComponent("page-\(page + 1)").path
            try Direct2DPageRenderer.renderPNG(
                pages: pages, page: page, pxPerMM: Self.pxPerMM, fontFiles: fontFiles, to: prefix + "-direct2d.png",
            )
            try pdf.writePNG(page: page, pxPerMM: Self.pxPerMM, to: prefix + "-pdf.png")
            let drawn = try pdf.pixels(page: page, pxPerMM: Self.pxPerMM)
            let size = pages.pageSizeMM(page)
            let width = Int((size.width * Self.pxPerMM).rounded(.up))
            let height = Int((size.height * Self.pxPerMM).rounded(.up))
            let direct = try Direct2DPageRenderer.renderPixels(
                pages.pages[page].commands, widthPx: width, heightPx: height, pxPerMM: Self.pxPerMM,
                offsetPx: (0, 0), fontFiles: fontFiles,
            )
            let comparison = InkComparison(
                a: direct, aWidth: width, b: drawn.bgra, bWidth: drawn.width,
                width: min(width, drawn.width), height: min(height, drawn.height),
            )
            print(
                "page \(page + 1): Direct2D ink \(comparison.inkA) px, PDF ink \(comparison.inkB) px; "
                    + String(
                        format: "missing from the PDF %.2f %%, from Direct2D %.2f %%",
                        comparison.missingFromB,
                        comparison.missingFromA,
                    ),
            )
            passed = passed && comparison.missingFromB <= 2 && comparison.missingFromA <= 2
        }
        return passed
    }
}

/// Dark pixels in two BGRA images of the same page, and the share of each one's that has no dark pixel within one of
/// it in the other.
struct InkComparison {
    let inkA: Int
    let inkB: Int
    let missingFromA: Double
    let missingFromB: Double

    init(a: [UInt8], aWidth: Int, b: [UInt8], bWidth: Int, width: Int, height: Int) {
        func dark(_ pixels: [UInt8], _ stride: Int, _ x: Int, _ y: Int) -> Bool {
            let offset = (y * stride + x) * 4
            return max(pixels[offset], pixels[offset + 1], pixels[offset + 2]) < 128
        }
        func near(_ pixels: [UInt8], _ stride: Int, _ x: Int, _ y: Int) -> Bool {
            for dy in -1 ... 1 {
                for dx in -1 ... 1 {
                    let nx = x + dx
                    let ny = y + dy
                    if nx >= 0, ny >= 0, nx < width, ny < height, dark(pixels, stride, nx, ny) { return true }
                }
            }
            return false
        }
        var inkA = 0
        var inkB = 0
        var lostA = 0
        var lostB = 0
        for y in 0 ..< height {
            for x in 0 ..< width {
                if dark(a, aWidth, x, y) {
                    inkA += 1
                    if !near(b, bWidth, x, y) { lostB += 1 }
                }
                if dark(b, bWidth, x, y) {
                    inkB += 1
                    if !near(a, aWidth, x, y) { lostA += 1 }
                }
            }
        }
        self.inkA = inkA
        self.inkB = inkB
        missingFromB = inkA == 0 ? 0 : Double(lostB) / Double(inkA) * 100
        missingFromA = inkB == 0 ? 0 : Double(lostA) / Double(inkB) * 100
    }
}
