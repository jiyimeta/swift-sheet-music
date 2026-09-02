#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

/// The frame the raster front-end's output lives in, and the only
/// sanctioned way in or out of it.
///
/// A degraded page has three coordinate frames: clean page space (where
/// ground-truth labels live), **source pixel space** — the raster the
/// front-end was handed — and **deskewed pixel space**, which is what it
/// emits in. `buildScore` needs glyphs and paths in ONE frame, and on a
/// clean raster all three coincide, so a frame mistake here is invisible
/// until the first degraded measurement and then presents as "the
/// detector is bad" rather than as a bookkeeping bug.
struct PageTransform {
    var dpi: Double
    /// Size of the raster, in pixels. Deskew preserves the canvas, so
    /// this is both the source and the deskewed size.
    var widthPx: Int
    var heightPx: Int
    /// The rotation deskew removed, in degrees, positive
    /// counter-clockwise.
    var deskewDegrees: Double

    /// Deskewed pixel (y-down, top-left origin) → PDF page point (y-up,
    /// bottom-left origin).
    func point(x: Double, y: Double) -> CGPoint {
        let scale = 72.0 / dpi
        return CGPoint(
            x: CGFloat(x * scale),
            y: CGFloat((Double(heightPx) - y) * scale),
        )
    }

    /// SOURCE pixel (the raster as handed over, before deskew) → PDF page
    /// point in the front-end's own frame.
    ///
    /// This is what a caller needs to bring anything measured against the
    /// original image — ground-truth labels, an external annotation —
    /// into the same frame as the emitted paths. `RasterPage.rotate`
    /// samples the source at `S(−θ)·(out − c) + c`, so the forward map
    /// from source to output is its inverse, `S(θ)·(src − c) + c`.
    func pagePoint(fromSourcePixelX x: Double, y: Double) -> CGPoint {
        let centerX = Double(widthPx - 1) / 2
        let centerY = Double(heightPx - 1) / 2
        let t = deskewDegrees * .pi / 180
        let dx = x - centerX
        let dy = y - centerY
        return point(
            x: cos(t) * dx + sin(t) * dy + centerX,
            y: -sin(t) * dx + cos(t) * dy + centerY,
        )
    }

    /// The page size `buildScore` must be given for these paths — the
    /// front-end's own raster, not the clean page it was degraded from.
    var pageSize: CGSize {
        let scale = 72.0 / dpi
        return CGSize(
            width: CGFloat(Double(widthPx) * scale),
            height: CGFloat(Double(heightPx) * scale),
        )
    }
}
