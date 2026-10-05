import CDirect2D
import Foundation

/// A PDF loaded by Windows' own PDF engine (Windows.Data.Pdf), whose pages Direct2D draws through the engine's
/// interop — sharp at any scale, with the file's annotations. A host shows a PDF score with it; `writePNG` draws a page
/// for a thumbnail.
///
/// Load it off the UI thread: opening waits on a WinRT async operation. Measured on folino's QA machine (2-core, 2017):
/// opening takes 15–100 ms; drawing a page costs what its content costs — 4–75 ms for most pages at 4× the screen's
/// scale, up to 300 ms for a dense MuseScore page — whatever part of the page is drawn.
///
/// Sendable so a host can open it on a background task and hand it to the UI thread: nothing in it changes after
/// `init`, and the document it holds is a WinRT `PdfDocument`, which is agile (callable from any apartment). Use it
/// from one thread at a time — the surface that shows it, or a thumbnail's `writePNG` — not from two at once.
public final class ScorePDF: @unchecked Sendable {
    let handle: OpaquePointer
    /// Each page's size in millimetres, read when the file is opened.
    private let sizesMM: [(width: Double, height: Double)]

    /// Opens the PDF at `path` and reads its pages' sizes. Throws when Windows cannot read it (not a PDF, damaged,
    /// password-protected).
    public init(path: String) throws {
        var created: OpaquePointer?
        var count: UInt32 = 0
        try Direct2DPageRenderer.check(withWide(path) { cd2d_pdf_open($0, &created, &count) }, "opening \(path)")
        guard let created else { throw Direct2DPageRenderer.Failure(step: "opening \(path)", hresult: -1) }
        var sizes: [(width: Double, height: Double)] = []
        for page in 0 ..< UInt32(count) {
            var width: Float = 0
            var height: Float = 0
            let hresult = cd2d_pdf_page_size(created, page, &width, &height)
            guard hresult == 0 else {
                cd2d_pdf_close(created)
                throw Direct2DPageRenderer.Failure(step: "page \(page + 1) of \(path)", hresult: hresult)
            }
            sizes.append((Double(width) * Self.mmPerDIP, Double(height) * Self.mmPerDIP))
        }
        handle = created
        sizesMM = sizes
    }

    deinit {
        cd2d_pdf_close(handle)
    }

    /// The number of pages.
    public var pageCount: Int {
        sizesMM.count
    }

    /// Page `page`'s size in millimetres, from the DIPs (1/96 inch) the PDF reports; `page` must be below `pageCount`.
    public func pageSizeMM(_ page: Int) -> (width: Double, height: Double) {
        sizesMM[page]
    }

    /// Draws page `page` whole on white at `pxPerMM` and writes it as PNG to `pngPath` — a thumbnail.
    public func writePNG(page: Int, pxPerMM: Double, to pngPath: String) throws {
        try checkPage(page)
        try Direct2DPageRenderer.check(
            withWide(pngPath) { cd2d_pdf_write_png(handle, UInt32(page), Float(pxPerMM * Self.mmPerDIP), $0) },
            "drawing page \(page + 1) of \(pngPath)",
        )
    }

    /// Page `page` drawn whole on white at `pxPerMM`: its pixel size and its pixels (BGRA premultiplied, top-down).
    package func pixels(page: Int, pxPerMM: Double) throws -> (width: Int, height: Int, bgra: [UInt8]) {
        try checkPage(page)
        let size = pageSizeMM(page)
        let width = Self.pixels(size.width * pxPerMM)
        let height = Self.pixels(size.height * pxPerMM)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try Direct2DPageRenderer.check(
            pixels.withUnsafeMutableBufferPointer {
                cd2d_pdf_render_pixels(
                    handle, UInt32(page), Float(pxPerMM * Self.mmPerDIP), $0.baseAddress, UInt32(width),
                    UInt32(height),
                )
            },
            "drawing page \(page + 1)",
        )
        return (width, height, pixels)
    }

    /// Millimetres in a DIP: a DIP is 1/96 inch.
    static let mmPerDIP = 25.4 / 96

    /// Whole pixels covering `extent`, as `cd2d_pdf_write_png` counts them: up, but not for the float noise in a size
    /// that is a whole number of pixels (an A4 width at 2 px/mm reads 420.00002).
    static func pixels(_ extent: Double) -> Int {
        max(1, Int(extent + 0.999))
    }

    private func checkPage(_ page: Int) throws {
        guard (0 ..< pageCount).contains(page) else {
            let invalidArgument = Int32(bitPattern: 0x8007_0057) // E_INVALIDARG
            throw Direct2DPageRenderer.Failure(step: "page \(page + 1) of \(pageCount)", hresult: invalidArgument)
        }
    }
}
