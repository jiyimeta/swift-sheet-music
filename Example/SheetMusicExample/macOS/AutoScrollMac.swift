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
            horizontal: false
        )
        withAnimation(.easeInOut(duration: 0.25)) {
            proxy.scrollTo(
                VerticalSystemAnchorID(systemIndex: sys),
                anchor: unit
            )
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
            x: targetX, y: horizontalScrollY
        )
    }

    /// Request a scroll to the leading edge of `measureIndex`, but
    /// only if the measure isn't already visible. Used by the
    /// note-input path on apply / undo / redo. Unlike
    /// `autoScrollHorizontalMac`, this is NOT gated on playback state
    /// — the user's last edit is the focal point regardless.
    ///
    /// Visibility check accounts for two occluders:
    ///   * The hosting-view `contentInset` (left padding inside the
    ///     score scroll view).
    ///   * The horizontal sticky header pane, which overlays the
    ///     leading edge of the viewport once the user has scrolled
    ///     past the score's bracket. Its width in doc coords is the
    ///     position of the first staff's left edge.
    @available(macOS 15.0, *)
    @MainActor
    func scrollToMeasureMac(
        measureIndex: Int,
        doc: LayoutDocument,
        viewportWidth: CGFloat,
        magnification: CGFloat,
        horizontalScrollX: CGFloat,
        horizontalScrollY: CGFloat,
        pendingScroll: Binding<CGPoint?>
    ) {
        guard let origin = doc.measureOrigin(measureIndex: measureIndex)
        else { return }
        let inset = MagnifyingScoreScrollView.contentInset
        let mag = max(0.01, magnification)
        let visibleDocWidth = viewportWidth / mag
        // Sticky header geometry — mirrors `HorizontalScoreContainer`.
        // The pane appears once `horizontalScrollX > bracketHostingX`
        // and overlays the leading edge with the score's clef / key /
        // time / bracket area. In doc coords, its width is the first
        // staff's leading X.
        let staffStartDocX = doc.systems.first?
            .staffOrigins.first?.x ?? 0
        let bracketDocX = staffStartDocX - doc.metrics.sp / 2
        let bracketHostingX = inset + bracketDocX
        let stickyVisible = horizontalScrollX > bracketHostingX
        let stickyDocWidth: CGFloat = stickyVisible ? staffStartDocX : 0

        let visibleDocLeft = horizontalScrollX - inset + stickyDocWidth
        let visibleDocRight = horizontalScrollX - inset + visibleDocWidth
        // Use the next measure's origin (or a fallback) to approximate
        // this measure's right edge — `measureOrigin` doesn't expose
        // width directly.
        let nextOrigin = doc.measureOrigin(measureIndex: measureIndex + 1)
        let measureRight: CGFloat = nextOrigin?.x
            ?? (origin.x + (doc.size.width / 16))
        let isOffscreenLeft = origin.x < visibleDocLeft
        let isOffscreenRight = measureRight > visibleDocRight
        if !isOffscreenLeft && !isOffscreenRight {
            return
        }
        // Direction-aware target:
        //   * Off-left (under sticky or scrolled past) → snap measure
        //     leading edge to the visible left, compensating for the
        //     sticky pane when it'd cover the target.
        //   * Off-right (typing past the visible window) → bring the
        //     measure into the right portion of the viewport with a
        //     generous trailing margin so the next few measures of
        //     headroom are visible without immediately scrolling again.
        let targetX: CGFloat
        if isOffscreenLeft {
            let rawTarget = max(0, origin.x)
            let stickyAfterScroll = rawTarget > bracketHostingX
            targetX = stickyAfterScroll
                ? max(0, origin.x - stickyDocWidth)
                : rawTarget
        } else {
            // Place the measure so ~30 % of the viewport sits to its
            // right as breathing room. (70 % from the left.)
            let rightMarginRatio: CGFloat = 0.3
            targetX = max(0, origin.x - visibleDocWidth * (1 - rightMarginRatio))
        }
        pendingScroll.wrappedValue = CGPoint(
            x: targetX, y: horizontalScrollY
        )
    }
#endif
