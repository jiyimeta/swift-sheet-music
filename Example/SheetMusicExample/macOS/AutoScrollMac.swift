#if os(macOS)
import SheetMusic
import SheetMusicUI
import SwiftUI

/// Re-evaluated on every cursor change (chord / rest level).
/// When the cursor's system has no overlap with the visible
/// band, scroll the nearest staff edge to the matching viewport
/// edge:
///
///   * Off-screen below → bottom staff bottom → viewport bottom.
///   * Off-screen above → top staff top → viewport top.
///
/// The system-overlap visibility check is itself the dedup:
/// once the scroll lands, the system overlaps the viewport and
/// subsequent chord / rest changes short-circuit.
@available(macOS 15.0, *)
@MainActor
func autoScrollVerticalMac(
    cursor: ScoreCursor?,
    doc: LayoutDocument?,
    isPlaying: Bool,
    viewportHeight: CGFloat,
    systemFrames: [Int: CGRect],
    proxy: ScrollViewProxy
) {
    guard isPlaying, let cursor, let doc else { return }
    let mi = cursor.measureIndex
    guard let sys = doc.systemIndex(forMeasureIndex: mi),
          let frame = systemFrames[sys]
    else { return }
    if isAnchorFullyVisible(
        anchorMin: frame.minY, anchorMax: frame.maxY,
        anchorSize: frame.height,
        viewportSize: viewportHeight
    ) { return }
    let pad: CGFloat = 8 * doc.metrics.sp
    let unit = paddedScrollAnchor(
        aboveViewport: frame.minY < 0,
        anchorSize: frame.height,
        viewportSize: viewportHeight,
        pad: pad,
        horizontal: false)
    withAnimation(.easeInOut(duration: 0.25)) {
        proxy.scrollTo(
            VerticalSystemAnchorID(systemIndex: sys),
            anchor: unit)
    }
}

/// Same idea for horizontal mode: snap the measure to the
/// leading edge via the wrapper's pending-scroll target. Goes
/// through `MagnifyingScoreScrollView`'s `pendingScrollTarget`
/// binding, which animates with `NSAnimationContext`.
@available(macOS 15.0, *)
@MainActor
func autoScrollHorizontalMac(
    cursor: ScoreCursor?,
    doc: LayoutDocument,
    score: Score,
    isPlaying: Bool,
    viewportWidth: CGFloat,
    magnification: CGFloat,
    horizontalScrollX: CGFloat,
    horizontalScrollY: CGFloat,
    pendingScroll: Binding<CGPoint?>
) {
    guard isPlaying,
          let cursor,
          let cursorRect = doc.cursorFrame(for: cursor, in: score),
          let origin = doc.measureOrigin(measureIndex: cursor.measureIndex)
    else { return }
    let inset = MagnifyingScoreScrollView.contentInset
    // `horizontalScrollX` lives in document / clip-view coords;
    // converting to doc coords removes the `inset`-padding around
    // the score so we compare in the same frame as `cursorRect`.
    // Pinch-zoom shrinks the doc-coord region visible inside the
    // clip view: `clipView.bounds.size = clipView.frame.size /
    // magnification`. So the visible doc-coord width is the
    // screen-space `viewportWidth` divided by the live magnification.
    let mag = max(0.01, magnification)
    let visibleDocWidth = viewportWidth / mag
    let visibleDocLeft = horizontalScrollX - inset
    let visibleDocRight = visibleDocLeft + visibleDocWidth
    let cursorVisible = cursorRect.minX >= visibleDocLeft
        && cursorRect.maxX <= visibleDocRight
    if cursorVisible { return }
    // Target: measure leading edge so the measure lands at the
    // visible leading edge after the scroll. Reads back through
    // the clipView coord space (= horizontalScrollX's frame),
    // which is offset from doc by `inset`.
    let targetX = max(0, origin.x)
    pendingScroll.wrappedValue = CGPoint(
        x: targetX, y: horizontalScrollY)
}
#endif
