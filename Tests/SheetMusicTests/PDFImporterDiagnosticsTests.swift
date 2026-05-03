import CoreGraphics
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicPDF
import Testing

@Suite @MainActor struct PDFImporterDiagnosticsTests {
    /// `PDFImportOptions.diagnostics` is `@Sendable`, so a captured
    /// `var` array can't be mutated from inside the closure under
    /// strict concurrency. A reference-typed sink sidesteps that —
    /// the `Mutex` keeps mutation race-free even though tests are
    /// single-threaded.
    private final class DiagnosticSink: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [PDFImportDiagnostic] = []
        func append(_ d: PDFImportDiagnostic) {
            lock.lock(); defer { lock.unlock() }
            items.append(d)
        }

        var snapshot: [PDFImportDiagnostic] {
            lock.lock(); defer { lock.unlock() }
            return items
        }
    }

    private static func makeRawGlyph(codepoint: UInt32) -> RawGlyph {
        RawGlyph(
            codepoint: codepoint,
            fontName: "Bravura",
            fontSize: 20,
            origin: CGPoint(x: 100, y: 700),
            advance: 5,
            pageIndex: 0
        )
    }

    @Test func unknownCodepointEmitsInfoDiagnostic() {
        let sink = DiagnosticSink()
        var opts = PDFImportOptions()
        opts.diagnostics = { d in sink.append(d) }
        let glyph = ClassifiedGlyph(
            raw: Self.makeRawGlyph(codepoint: 0xE999),
            semantic: .unknown(0xE999)
        )
        PDFImporter.emitUnknownGlyphDiagnostics([glyph], options: opts)
        let captured = sink.snapshot
        #expect(captured.count == 1)
        #expect(captured.first?.severity == .info)
        #expect(captured.first?.message.contains("E999") == true)
    }

    @Test func nilCallbackIsSilent() {
        var opts = PDFImportOptions()
        opts.diagnostics = nil
        let glyph = ClassifiedGlyph(
            raw: Self.makeRawGlyph(codepoint: 0xE999),
            semantic: .unknown(0xE999)
        )
        // Must not crash; no observable side-effect.
        PDFImporter.emitUnknownGlyphDiagnostics([glyph], options: opts)
    }

    @Test func recognisedCodepointsDoNotFire() {
        let sink = DiagnosticSink()
        var opts = PDFImportOptions()
        opts.diagnostics = { d in sink.append(d) }
        let glyph = ClassifiedGlyph(
            raw: Self.makeRawGlyph(codepoint: 0xE0A4),
            semantic: .noteheadBlack
        )
        PDFImporter.emitUnknownGlyphDiagnostics([glyph], options: opts)
        #expect(sink.snapshot.isEmpty)
    }

    @Test func endToEndPipelineWithDiagnosticsCallback() {
        let sink = DiagnosticSink()
        var opts = PDFImportOptions()
        opts.diagnostics = { d in sink.append(d) }
        // A degenerate PDF (empty data) throws — the callback plumbing
        // through `parse` must not crash regardless of whether any
        // diagnostics fired.
        #expect(throws: SheetMusicError.self) {
            _ = try PDFImporter.parse(pdfData: Data(), options: opts)
        }
        // sink may be empty; the test confirms opts/closure plumbing
        // does not crash on the throwing path.
        _ = sink.snapshot
    }
}
