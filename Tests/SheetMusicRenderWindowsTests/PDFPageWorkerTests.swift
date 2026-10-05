import Foundation
@testable import SheetMusicRenderWindows
import Testing

/// `PDFPageWorker`: the thread that draws a PDF's pages for the surface, over `ScorePDFTests`' one-page A4 with its
/// black square (centred 144 pt from the left and 99.89 pt from the top, 144 × 100 pt).
struct PDFPageWorkerTests {
    private static let pxPerMM = 2.0

    private static func job(page: Int = 0, _ rect: PixelRect) -> PDFPageWorker.Job {
        PDFPageWorker.Job(
            key: TileKey(page: page, column: 0, row: 0, scale: TileKey.scaleKey(pxPerMM)), rect: rect, pxPerMM: pxPerMM,
        )
    }

    /// What the worker finished, once it has finished `count` jobs — 10 s at most.
    private static func finished(_ worker: PDFPageWorker, count: Int) async throws -> [PDFPageWorker.Finished] {
        var done: [PDFPageWorker.Finished] = []
        let clock = ContinuousClock()
        let start = clock.now
        while done.count < count, clock.now - start < .seconds(10) {
            done += worker.takeFinished()
            try await Task.sleep(for: .milliseconds(20))
        }
        return done
    }

    private static func pixel(_ bgra: [UInt8], width: Int, x: Int, y: Int) -> [UInt8] {
        let offset = (y * width + x) * 4
        return Array(bgra[offset ..< offset + 4])
    }

    @Test func `a wanted page is drawn on the worker, square black and the rest white`() async throws {
        let worker = try PDFPageWorker(pdf: ScorePDF(path: ScorePDFTests.squarePDF()))
        defer { worker.stop() }
        let whole = PixelRect(x: 0, y: 0, width: 420, height: 594)

        worker.want([Self.job(whole)])
        let done = try await Self.finished(worker, count: 1)

        try #require(done.count == 1)
        guard case let .drawn(bgra) = done[0].outcome else { Issue.record("\(done[0].outcome)"); return }
        let mmPerPoint = 25.4 / 72
        let centre = (x: Int(144 * mmPerPoint * Self.pxPerMM), y: Int(99.89 * mmPerPoint * Self.pxPerMM))
        #expect(Self.pixel(bgra, width: 420, x: centre.x, y: centre.y) == [0, 0, 0, 255])
        #expect(Self.pixel(bgra, width: 420, x: 300, y: 400) == [255, 255, 255, 255])
        #expect(!worker.isBusy)
    }

    /// The part of a page past the cap is drawn from its offset: the same pixels as that part of the whole page.
    @Test func `part of a page is drawn from its offset`() async throws {
        let pdf = try ScorePDF(path: ScorePDFTests.squarePDF())
        let worker = PDFPageWorker(pdf: pdf)
        defer { worker.stop() }
        let whole = try pdf.pixels(page: 0, pxPerMM: Self.pxPerMM)
        // Across the square's top-left corner: 51 × 35 pt in at 2 px/mm is about (36, 25) px.
        let part = PixelRect(x: 20, y: 10, width: 40, height: 40)

        worker.want([Self.job(part)])
        let done = try await Self.finished(worker, count: 1)

        try #require(done.count == 1)
        guard case let .drawn(bgra) = done[0].outcome else { Issue.record("\(done[0].outcome)"); return }
        var differing = 0
        for y in 0 ..< part.height {
            for x in 0 ..< part.width {
                let mine = Self.pixel(bgra, width: part.width, x: x, y: y)
                let wholes = Self.pixel(whole.bgra, width: whole.width, x: part.x + x, y: part.y + y)
                if zip(mine, wholes).contains(where: { abs(Int($0) - Int($1)) > 2 }) { differing += 1 }
            }
        }
        #expect(differing == 0)
        #expect(bgra.contains(0) && bgra.contains(255), "the part crosses the square's corner")
    }

    @Test func `a page that is not there fails rather than drawing`() async throws {
        let worker = try PDFPageWorker(pdf: ScorePDF(path: ScorePDFTests.squarePDF()))
        defer { worker.stop() }

        worker.want([Self.job(page: 3, PixelRect(x: 0, y: 0, width: 10, height: 10))])
        let done = try await Self.finished(worker, count: 1)

        try #require(done.count == 1)
        guard case .failed = done[0].outcome else { Issue.record("drew a page that is not there"); return }
    }

    @Test func `a stopped worker draws nothing more`() async throws {
        let worker = try PDFPageWorker(pdf: ScorePDF(path: ScorePDFTests.squarePDF()))

        worker.stop()
        worker.want([Self.job(PixelRect(x: 0, y: 0, width: 10, height: 10))])
        try await Task.sleep(for: .milliseconds(300))

        #expect(worker.takeFinished().isEmpty)
    }
}
