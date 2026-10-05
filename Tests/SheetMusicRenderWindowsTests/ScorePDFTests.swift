import Foundation
@testable import SheetMusicRenderWindows
import Testing

/// A PDF through Windows' own engine (`ScorePDF`): what it reads of a page and what it draws. The PDF is written here,
/// one A4 page with one black square and nothing else, so every pixel's expected colour is known.
struct ScorePDFTests {
    /// A one-page A4 PDF (595.276 × 841.89 pt) with a black square 144 × 100 pt whose top-left is 72 pt from the left
    /// and 49.89 pt from the top (PDF's y runs up: the square's bottom edge sits at y = 692).
    static func squarePDF() throws -> String {
        let content = "0 0 0 rg 72 692 144 100 re f\n"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595.276 841.89] /Contents 4 0 R >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)endstream",
        ]
        var body = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(body.utf8.count)
            body += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = body.utf8.count
        body += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            body += String(format: "%010d 00000 n \n", offset)
        }
        body += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        let url = FileManager.default.temporaryDirectory.appending(path: "score-pdf-\(UUID().uuidString).pdf")
        try Data(body.utf8).write(to: url)
        return try #require(url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } })
    }

    @Test func `a page reads as one A4 page in millimetres`() throws {
        let pdf = try ScorePDF(path: Self.squarePDF())

        let size = pdf.pageSizeMM(0)

        #expect(pdf.pageCount == 1)
        #expect(abs(size.width - 210) < 0.1)
        #expect(abs(size.height - 297) < 0.1)
    }

    @Test func `a page draws its square black and leaves the rest white`() throws {
        let pdf = try ScorePDF(path: Self.squarePDF())
        let pxPerMM = 2.0 // 420 × 594 px
        let drawn = try pdf.pixels(page: 0, pxPerMM: pxPerMM)
        func pixel(atMM x: Double, _ y: Double) -> [UInt8] {
            let offset = (Int(y * pxPerMM) * drawn.width + Int(x * pxPerMM)) * 4
            return Array(drawn.bgra[offset ..< offset + 4])
        }
        let millimetresPerPoint = 25.4 / 72

        #expect(drawn.width == 420)
        // The square's centre: 144 pt from the left, 99.89 pt from the top.
        #expect(pixel(atMM: 144 * millimetresPerPoint, 99.89 * millimetresPerPoint) == [0, 0, 0, 255])
        // Well outside it.
        #expect(pixel(atMM: 150, 200) == [255, 255, 255, 255])
    }

    /// `URL.path` on Windows separates with `/`, which the WinRT file API refuses on its own.
    @Test func `a path written with forward slashes opens`() throws {
        let native = try Self.squarePDF()
        let forward = String(native.map { $0 == "\\" ? "/" : $0 })

        let pdf = try ScorePDF(path: forward)

        #expect(pdf.pageCount == 1)
    }

    /// What a host does: open it on a background task, draw it on another thread.
    @Test func `a PDF opened on a background task draws on another thread`() async throws {
        let path = try Self.squarePDF()
        let pdf = try await Task.detached { try ScorePDF(path: path) }.value

        let drawn = try await Task.detached { try pdf.pixels(page: 0, pxPerMM: 1) }.value

        #expect(drawn.width == 210)
        #expect(drawn.bgra.contains(0))
    }

    @Test func `a page that is not there throws rather than drawing`() throws {
        let pdf = try ScorePDF(path: Self.squarePDF())

        #expect(throws: Direct2DPageRenderer.Failure.self) {
            try pdf.pixels(page: 1, pxPerMM: 1)
        }
        #expect(throws: Direct2DPageRenderer.Failure.self) {
            try pdf.writePNG(page: -1, pxPerMM: 1, to: "unused.png")
        }
    }

    @Test func `a file that is not a PDF throws`() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "not-a-pdf-\(UUID().uuidString).pdf")
        try Data("not a pdf".utf8).write(to: url)
        let path = try #require(url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } })

        #expect(throws: Direct2DPageRenderer.Failure.self) {
            try ScorePDF(path: path)
        }
    }

    @Test func `a page writes as a PNG of its size`() throws {
        let pdf = try ScorePDF(path: Self.squarePDF())
        let url = FileManager.default.temporaryDirectory.appending(path: "score-pdf-\(UUID().uuidString).png")
        let path = try #require(url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } })

        try pdf.writePNG(page: 0, pxPerMM: 1, to: path)
        let png = try Data(contentsOf: url)

        #expect(Array(png.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
        // Width and height sit in the IHDR chunk, big-endian at bytes 16 and 20: 210 × 297 mm at 1 px per mm.
        let width = png[16 ..< 20].reduce(0) { $0 << 8 | Int($1) }
        let height = png[20 ..< 24].reduce(0) { $0 << 8 | Int($1) }
        #expect(width == 210)
        #expect(height == 297)
    }
}
