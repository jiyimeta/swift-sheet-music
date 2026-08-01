#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

/// Pulls annotation text back inside the system's horizontal bounds.
///
/// `LayoutEngine+Placement` positions a `<StaffText>` at its tick's X
/// column plus the author's `<offset>`, without consulting the text's
/// own width, and `SkylineAutoplacePass` only ever computes a `dy`.
/// Nothing else in the layout moves an element horizontally, so an
/// annotation anchored near the end of a system runs past the last
/// barline and off the page, where the host view clips it.
///
/// This pass runs BEFORE `SkylineAutoplacePass` so X is final by the
/// time the vertical pass measures collisions — clamping afterwards
/// could slide a text onto a notehead the vertical pass had already
/// cleared.
///
/// **Scope.** Only `.staffText` / `.systemText` / `.tempo` /
/// `.rehearsalMark` move. Lyrics are excluded because their X is
/// shared with the melisma lines and hyphens drawn between them, and
/// `.harmony` because its geometry lives in `LayoutHarmony.anchorX` +
/// `runs` rather than a plain origin; clamping either needs more than
/// an origin shift.
enum HorizontalClampPass {
    private static let clampedKinds: Set<ShapeItemKind> = [
        .staffText, .systemText, .tempo, .rehearsalMark,
    ]

    /// Clamp one staff of one system in place.
    ///
    /// - Parameters:
    ///   - measures: `measures[i]` is one measure's element array for
    ///     ONE staff, with measure-local origins.
    ///   - xOffsets: `xOffsets[i]` is that measure's accumulated system
    ///     X. Must have the same count as `measures`.
    ///   - systemLeftX: left edge of the first measure — i.e. the right
    ///     edge of the instrument-name gutter, not x = 0.
    ///   - systemRightX: right edge of the last measure. Every system,
    ///     the last one included, is stretched to the available content
    ///     width, so this is the page's content right edge.
    static func run(
        measures: inout [[LayoutElement]],
        xOffsets: [CGFloat],
        systemLeftX: CGFloat,
        systemRightX: CGFloat,
        metrics: StaffMetrics,
    ) {
        guard measures.count == xOffsets.count,
              systemRightX > systemLeftX else { return }
        for mIdx in measures.indices {
            for i in measures[mIdx].indices {
                let element = measures[mIdx][i]
                guard let kind = LayoutElementShape.kind(of: element),
                      clampedKinds.contains(kind),
                      let span = horizontalExtent(
                          of: element, kind: kind,
                          xOffset: xOffsets[mIdx], metrics: metrics,
                      )
                else { continue }
                let dx = shift(
                    for: span,
                    systemLeftX: systemLeftX,
                    systemRightX: systemRightX,
                )
                guard dx != 0 else { continue }
                measures[mIdx][i] = LayoutEngine.translateX(
                    element: element, dx: dx,
                )
            }
        }
    }

    /// System-X span of `element`'s ink, or `nil` when it has no
    /// measurable shape. Unions the rects by hand rather than through
    /// `CGRect.union` / `offsetBy`, matching `LayoutShape.bbox` — this
    /// target compiles for Android, where `CGRect` comes from
    /// Foundation rather than CoreGraphics.
    private static func horizontalExtent(
        of element: LayoutElement, kind: ShapeItemKind,
        xOffset: CGFloat, metrics: StaffMetrics,
    ) -> (minX: CGFloat, maxX: CGFloat)? {
        let rects = LayoutElementShape.autoplacedRects(
            for: element, kind: kind, metrics: metrics,
        )
        guard let first = rects.first else { return nil }
        var minX = first.minX
        var maxX = first.maxX
        for rect in rects.dropFirst() {
            minX = min(minX, rect.minX)
            maxX = max(maxX, rect.maxX)
        }
        return (minX + xOffset, maxX + xOffset)
    }

    /// How far left (negative) or right (positive) `span` must move to
    /// fit inside the system. Zero when it already fits.
    ///
    /// The right edge is tested first and the left edge second, so the
    /// left bound wins if both apply. That only happens for text wider
    /// than the whole system, where the choice is which end to sacrifice
    /// — starting at the left edge keeps the beginning of the text
    /// readable, which is the same trade-off any left-to-right overflow
    /// makes.
    private static func shift(
        for span: (minX: CGFloat, maxX: CGFloat),
        systemLeftX: CGFloat, systemRightX: CGFloat,
    ) -> CGFloat {
        var dx = min(0, systemRightX - span.maxX)
        dx = max(dx, systemLeftX - span.minX)
        return dx
    }
}
