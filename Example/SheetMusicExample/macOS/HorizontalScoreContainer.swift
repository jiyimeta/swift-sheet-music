#if os(macOS)
import SheetMusic
import SheetMusicAudio
import SheetMusicUI
import SwiftUI

/// macOS horizontal-mode score viewport: `MagnifyingScoreScrollView`
/// for the score itself, plus a sticky header pane that takes over
/// the leading edge once the score has scrolled past its bracket.
///
/// All the geometry math (bracket position, sticky-pane visibility
/// threshold, sticky lookup X) lives here so `ContentViewMac.body`
/// is just a per-mode dispatcher.
@available(macOS 15.0, *)
struct HorizontalScoreContainer: View {
    let score: Score
    let document: LayoutDocument
    let measureContexts: [LayoutMeasureContext]
    @Binding var magnification: CGFloat
    @Binding var horizontalScrollX: CGFloat
    @Binding var horizontalScrollY: CGFloat
    @Binding var pendingHorizontalScroll: CGPoint?
    let selection: ScoreSelection
    let voiceColors: [Int: Color]
    let playbackCursor: ScoreCursor?
    let isMarqueeMode: Bool
    let onTap: (CGPoint) -> Void
    let onMarqueeEnd: (CGRect, LayoutDocument) -> Void
    /// Fired on every cursor change with the current viewport
    /// width. The host calls back into its `autoScrollHorizontal`
    /// implementation, which reads `horizontalScrollX` / etc. from
    /// its own state.
    let onCursorChange: (ScoreCursor?, CGFloat) -> Void
    /// Forwarded to `MagnifyingScoreScrollView.contentVersion`.
    /// Bumped by the host when an edit changes glyph content
    /// without changing `document.size`, so the scroll view's
    /// optimisation guard doesn't swallow the refresh.
    var contentVersion: AnyHashable? = nil
    /// Reports the score area's live viewport size to the host so
    /// it can decide whether an offscreen measure needs an
    /// auto-scroll on edit. Fires on first layout and on every
    /// resize. Optional — preserves callers that don't need it.
    var onViewportSizeChange: ((CGSize) -> Void)? = nil

    @State private var marqueeRect: CGRect?

    var body: some View {
        let inset = MagnifyingScoreScrollView.contentInset
        // Bracket position in hostingView coords (unmag).
        // The bracket sits half a space to the LEFT of the
        // first staff's leading edge — see
        // `ScoreCanvas.swift:91-104` /
        // `ScoreLayerBuilder.drawBracket`. The sticky
        // pane's visibility threshold and its horizontal
        // shift both pivot on this position, so when the
        // score's bracket reaches the viewport's leading
        // edge the sticky takes over with its own bracket
        // landing at the exact same viewport X.
        let staffStartDocX = document.systems.first?
            .staffOrigins.first?.x ?? 0
        let bracketDocX = staffStartDocX
            - document.metrics.sp / 2
        let bracketHostingX = inset + bracketDocX
        // Score-relative X (unmagnified) of the leftmost
        // visible score pixel.
        let scoreScrollX = max(
            0, horizontalScrollX - inset)
        // The measure to display in the sticky is driven by
        // its TRAILING edge, not the leftmost-visible pixel
        // (which is hidden behind the pane). That way the
        // displayed measure number flips the moment the
        // NEXT measure's leading barline crosses the pane's
        // trailing edge — i.e. the moment that measure
        // becomes the first thing the user actually sees.
        let stickyLookupX = document.stickyTrailingX(
            scoreScrollX: scoreScrollX,
            measureContexts: measureContexts)
        // Hide the sticky until the user has scrolled far
        // enough that the score's bracket has reached the
        // viewport's leading edge. Below that the bracket
        // and everything that follows it are still in
        // their natural unscrolled positions, so showing
        // the sticky would only duplicate what's already
        // on screen.
        ZStack(alignment: .topLeading) {
            MagnifyingScoreScrollView(
                document: document, score: score,
                magnification: $magnification,
                documentScrollX: $horizontalScrollX,
                documentScrollY: $horizontalScrollY,
                pendingScrollTarget: $pendingHorizontalScroll,
                selection: selection,
                voiceColors: voiceColors,
                playbackCursor: playbackCursor,
                isMarqueeMode: isMarqueeMode,
                marqueeRect: $marqueeRect,
                onTap: onTap,
                onMarqueeEnd: { rect in
                    onMarqueeEnd(rect, document)
                },
                contentVersion: contentVersion)
                .background(
                    GeometryReader { hgeo in
                        Color.clear
                            .onAppear {
                                onViewportSizeChange?(hgeo.size)
                            }
                            .onChange(of: hgeo.size) { _, newSize in
                                onViewportSizeChange?(newSize)
                            }
                            .onChange(of: playbackCursor) { _, newCursor in
                                onCursorChange(newCursor, hgeo.size.width)
                            }
                    })
            if horizontalScrollX > bracketHostingX {
                StickyHeaderView(
                    document: document,
                    measureContexts: measureContexts,
                    documentScrollX: stickyLookupX)
                    // Match the score's `.padding(inset)`
                    // exactly so vertical alignment is
                    // identical: leading + top padding put
                    // the sticky's white area at the same
                    // (inset, inset) corner as the score's
                    // own white background.
                    .padding(.leading, inset)
                    .padding(.top, inset)
                    // Track vertical scroll: the sticky's
                    // staves stay locked to the score's
                    // staves when zoomed past the viewport
                    // height. Horizontally, shift left by
                    // `bracketHostingX` so the pane's
                    // bracket renders at viewport x = 0 —
                    // exactly where the score's bracket
                    // sits at the visibility threshold,
                    // making the transition seamless and
                    // every other element (clef / key /
                    // time / staff name) overlap its
                    // counterpart at that scroll amount.
                    .offset(
                        x: -bracketHostingX,
                        y: -horizontalScrollY)
                    .scaleEffect(
                        magnification, anchor: .topLeading)
                    .allowsHitTesting(false)
            }
        }
        // Confine the sticky to the same rect the score
        // scroll view occupies — without this, scaleEffect's
        // overflow can paint into the sidebar / window
        // toolbar, since SwiftUI doesn't auto-clip
        // transformed content. `.contentShape` keeps tap
        // hit-testing aligned with the visible region.
        .clipped()
        .contentShape(Rectangle())
    }
}
#endif
