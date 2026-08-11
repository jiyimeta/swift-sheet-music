#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import Foundation

/// One page's raster analysis: the `paths` half of `WalkedContent`, plus
/// the frame those paths live in.
///
/// The transform travels WITH the paths on purpose. A degraded page has
/// three coordinate frames — clean page space (where ground-truth labels
/// live), degraded pixel space (what this stage is handed) and deskewed
/// pixel space (what it emits in) — and on a clean raster all three
/// coincide, so a frame mistake is invisible until the first degraded
/// measurement and then presents as "the detector is bad".
struct RasterPageAnalysis {
    var paths: [PathSegment]
    /// The frame `paths` are in — and the only sanctioned way to bring
    /// anything else into it. A degraded page has been resampled, so its
    /// pixel size is NOT the clean page size times dpi/72; a consumer
    /// that reconstructed it from a label's page size would hand
    /// `buildScore` a page that disagrees with the paths on it.
    var transform: PageTransform
    /// Measured staff spacing in points; 0 when the page has no staff.
    var staffSpacingPt: Double
    /// Rotation removed by deskew, in degrees, positive counter-clockwise.
    var deskewDegrees: Double

    /// The page size `buildScore` must be given for these paths.
    var pageSizePt: CGSize {
        transform.pageSize
    }
}

extension RasterPage {
    /// Binarize → deskew → re-binarize → staff lines, verticals, beams.
    ///
    /// Binarization runs twice by design: the first pass exists only to
    /// feed the skew estimator, and rotating a BINARY mask produces
    /// jagged edges that read as ink texture — at 200dpi a staff line is
    /// 1.2px thick, the same size as that texture — so the rotation is
    /// applied to the grayscale and the mask rebuilt from the result.
    ///
    /// A page with no detectable staff yields no paths rather than paths
    /// measured against a guessed scale: every threshold below is in
    /// staff spaces, and without a staff there is no space to measure
    /// them in.
    static func analyze(_ bitmap: GrayBitmap, pageIndex: Int) -> RasterPageAnalysis {
        let angle = estimateSkewDegrees(binarize(bitmap))
        let straight = rotate(bitmap, degrees: -angle)
        let mask = binarize(straight)
        let transform = PageTransform(
            dpi: straight.dpi, widthPx: straight.width, heightPx: straight.height,
            deskewDegrees: angle,
        )
        guard let spacingPx = estimateStaffSpacingPx(mask) else {
            return RasterPageAnalysis(
                paths: [], transform: transform,
                staffSpacingPt: 0, deskewDegrees: angle,
            )
        }
        var paths = staffLineSegments(
            mask, spacingPx: spacingPx, transform: transform, pageIndex: pageIndex,
        )
        paths += verticalSegments(
            mask, spacingPx: spacingPx, transform: transform, pageIndex: pageIndex,
        )
        paths += beamSegments(
            mask, spacingPx: spacingPx, transform: transform, pageIndex: pageIndex,
        )
        return RasterPageAnalysis(
            paths: paths, transform: transform,
            staffSpacingPt: spacingPx * 72.0 / straight.dpi,
            deskewDegrees: angle,
        )
    }
}
