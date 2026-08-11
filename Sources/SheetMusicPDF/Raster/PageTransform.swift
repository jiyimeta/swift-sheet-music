#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

/// The frame the raster front-end's output lives in, and the only
/// sanctioned way to leave it.
///
/// A degraded page has three coordinate frames: clean page space (where
/// every ground-truth label lives), degraded pixel space (what the
/// front-end is handed), and deskewed pixel space (what its paths come
/// out in). `buildScore` needs glyphs and paths in ONE frame, and on a
/// clean raster all three coincide — so a frame mistake is invisible
/// until the first degraded measurement and then presents as "the
/// detector is bad" rather than as a bookkeeping bug. Returning this
/// alongside the paths is what makes the composition explicit.
struct PageTransform {
    var dpi: Double
    /// Height of the DESKEWED raster in pixels — the y-flip anchor.
    var heightPx: Int
    /// The rotation deskew removed, in degrees, positive
    /// counter-clockwise. Recorded so that a harness can compose ground
    /// truth into this same frame. `point(x:y:)` does not need it: the
    /// pixels were already rotated, so this frame is upright by
    /// construction.
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

    func pageSizePt(widthPx: Int) -> CGSize {
        let scale = 72.0 / dpi
        return CGSize(
            width: CGFloat(Double(widthPx) * scale),
            height: CGFloat(Double(heightPx) * scale),
        )
    }
}
