import CDirect2D
import Foundation
import SheetMusicBridgeCore

/// What probes and tests reach past the surface's drawing API for: fault injection, read-back, and cache sizes.
extension ScoreSurface {
    /// The next band end or present fails with `hresult` (the device-loss path without losing a device).
    package func failNext(hresult: Int32) {
        if let surface { cd2d_surface_debug_fail_next(surface, hresult) }
    }

    /// The next frame is also copied into `pixels` (BGRA, `width` x `height`, top-down) just before it is presented.
    package func readBackNext(into pixels: UnsafeMutablePointer<UInt8>, width: Int, height: Int) {
        if let surface { cd2d_surface_debug_read_back_next(surface, pixels, UInt32(width), UInt32(height)) }
    }

    /// Page `page` where `frame` puts it, rendered untiled — every command in one walk, no span or tile culling; for a
    /// PDF, the page drawn straight at the frame's scale — into one band the size of the surface, on the surface's own
    /// device, and read back: BGRA premultiplied (opaque, on white), `widthPx` x `heightPx`, top-down. What a frame at
    /// `frame`'s scale showing only that page must equal: the rasterizer is the same one, so a pixel that differs is
    /// the tiling's (a tile misplaced, a span not walked, a fill culled that reached the tile, a PDF page stretched
    /// from another scale). Other pages and the overlays are not drawn. Not during a frame.
    package func referencePixels(page: Int, frame: Frame) throws -> [UInt8] {
        let step = "rendering page \(page + 1) untiled"
        guard let surface else { throw Failure(step: step, hresult: Int32(bitPattern: 0x8000_FFFF)) } // E_UNEXPECTED
        guard pages.indices.contains(page), frame.pageOrigins.indices.contains(page) else {
            throw Failure(step: step, hresult: Int32(bitPattern: 0x8007_0057)) // E_INVALIDARG
        }
        let width = widthPx
        let height = heightPx
        var band: OpaquePointer?
        var canvas: OpaquePointer?
        try Self.check(cd2d_band_begin(surface, UInt32(width), UInt32(height), &band, &canvas), step)
        guard let band, let canvas else { throw Failure(step: step, hresult: -1) }
        defer { cd2d_band_release(surface, band) }
        // The offset the frame's tiles are placed from, so both sit on the same pixel grid.
        let offset = Self.pageOffsetPx(page, frame)
        var drawn: Int32 = 0
        if let pdf {
            drawn = cd2d_band_draw_pdf(
                surface, pdf.handle, UInt32(page), Float(frame.pxPerMM * ScorePDF.mmPerDIP), Float(-offset.x),
                Float(-offset.y),
            )
        } else {
            var walker = DrawCommandWalker(canvas: canvas, pxPerMM: frame.pxPerMM, offset: offset)
            walker.paint(pages[page].commands[...])
        }
        let ended = cd2d_band_end(surface, band)
        try Self.check(drawn, step)
        try Self.check(ended, step)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let hresult = pixels.withUnsafeMutableBufferPointer { buffer in
            cd2d_band_read_back(surface, band, buffer.baseAddress, UInt32(width), UInt32(height))
        }
        try Self.check(hresult, "reading page \(page + 1) back")
        return pixels
    }

    /// Score tiles, or PDF pages drawn, in the cache.
    package var tileCount: Int {
        tiles.count + pdfRasters.count
    }

    package var tileBytes: Int {
        tiles.bytes + pdfRasters.bytes
    }

    package var glyphCacheCount: Int {
        Int(cd2d_resources_glyph_cache_count(resources))
    }
}
