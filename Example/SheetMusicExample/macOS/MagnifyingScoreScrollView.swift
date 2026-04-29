#if os(macOS)
import AppKit
import SheetMusic
import SheetMusicAudio
import SheetMusicUI
import SwiftUI

/// Hosts a SwiftUI `ScoreView` inside an `NSScrollView` that provides
/// native pinch-to-zoom-around-cursor.
///
/// SwiftUI's own `ScrollView` + `MagnifyGesture` can be coordinated
/// manually, but the commit-time scroll offset update fights
/// concurrent content-size changes and the anchor drifts in
/// small-content axes.  AppKit already solves this with
/// `NSScrollView.allowsMagnification`, so we bridge instead of
/// reinventing it.
@available(macOS 15.0, *)
struct MagnifyingScoreScrollView: NSViewRepresentable {
    /// Padding (in document/unmagnified points) around the ScoreView
    /// inside the hosting view. Known so the click handler can
    /// subtract it when converting hosting-view coords to doc coords.
    static let contentInset: CGFloat = 16

    let document: LayoutDocument
    let score: Score
    @Binding var magnification: CGFloat
    /// Document-space X (unmagnified) of the visible left edge.
    /// Updated live as the user scrolls so a sticky header pane
    /// overlay can re-render its clef / key / time / measure-number
    /// state to match the leftmost visible measure.
    @Binding var documentScrollX: CGFloat
    /// Document-space Y (unmagnified) of the visible top edge.
    /// When the user zooms in past the viewport height, the score
    /// scrolls vertically too — the sticky pane needs to ride the
    /// same offset so its clef stays glued to the staff lines.
    @Binding var documentScrollY: CGFloat
    /// Programmatic scroll target in document coords. When set,
    /// the wrapper animates the clip view to that point and
    /// resets the binding to `nil`. Used by the playback auto-
    /// scroll path during full-score playback.
    @Binding var pendingScrollTarget: CGPoint?
    let selection: ScoreSelection
    let voiceColors: [Int: Color]
    let playbackCursor: ScoreCursor?
    let onTap: (CGPoint) -> Void

    private var rootView: AnyView {
        AnyView(
            ScoreView(
                document: document, score: score,
                selection: selection,
                voiceColors: voiceColors,
                playbackCursor: playbackCursor)
                .padding(Self.contentInset))
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.25
        scrollView.maxMagnification = 4.0
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.usesPredominantAxisScrolling = false

        let hosting = NSHostingView(rootView: rootView)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = hosting

        // Use an NSClickGestureRecognizer rather than SwiftUI's
        // `.onTapGesture` because SwiftUI does NOT compensate for
        // NSScrollView's magnification transform — the tap location
        // it reports drifts off the clicked note as soon as zoom
        // leaves 100 %. `gr.location(in:)` returns coords in the
        // hosting view's own (unmagnified) coord space, so we land
        // on the correct notehead at any zoom level.
        let click = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleClick(_:)))
        click.buttonMask = 0x1
        hosting.addGestureRecognizer(click)

        context.coordinator.hostingView = hosting
        context.coordinator.magnificationBinding = $magnification
        context.coordinator.documentScrollXBinding = $documentScrollX
        context.coordinator.documentScrollYBinding = $documentScrollY
        context.coordinator.contentInset = Self.contentInset
        context.coordinator.onTap = onTap
        // Seed the change-detection cache with the values we just
        // installed in `rootView`, so `updateNSView`'s short-circuit
        // doesn't re-render on the first benign re-eval.
        context.coordinator.lastSelection = selection
        context.coordinator.lastVoiceColors = voiceColors
        context.coordinator.lastDocumentSize = document.size
        context.coordinator.lastPlaybackCursor = playbackCursor

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.magnificationDidEnd(_:)),
            name: NSScrollView.didEndLiveMagnifyNotification,
            object: scrollView)
        // Pinch gesture: NSScrollView fires bounds-changed every
        // frame while magnifying because clipView's size shrinks
        // / grows around the magnification anchor. Each such
        // notification would invalidate the SwiftUI binding and
        // force a full body re-eval (and an NSHostingView refresh
        // of the score), making pinch feel laggy on big scores.
        // Track the live-magnify state so `boundsDidChange` can
        // bail out until the gesture finishes — we then fire one
        // catch-up update from `magnificationDidEnd`.
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.willStartLiveMagnify(_:)),
            name: NSScrollView.willStartLiveMagnifyNotification,
            object: scrollView)

        // Track the document-space scroll offset live. NSClipView's
        // bounds change every frame during a scroll; we mirror it
        // into the SwiftUI binding so an outer overlay (sticky
        // header pane) can re-render in sync.
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.boundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clipView)

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coord = context.coordinator
        coord.magnificationBinding = $magnification
        coord.documentScrollXBinding = $documentScrollX
        coord.documentScrollYBinding = $documentScrollY
        coord.onTap = onTap

        // Skip the rootView reassignment when none of its inputs
        // actually changed. SwiftUI re-evaluates this view's body
        // every time `documentScrollX` updates (60-120 Hz during
        // scroll), and assigning a fresh `AnyView` makes
        // NSHostingView walk the SwiftUI tree top-to-bottom each
        // time. Comparing `selection` and `voiceColors` is O(few
        // entries), so this guard pays for itself many times over.
        let selectionChanged = coord.lastSelection != selection
        let voiceColorsChanged = coord.lastVoiceColors != voiceColors
        let documentChanged = coord.lastDocumentSize != document.size
        let cursorChanged = coord.lastPlaybackCursor != playbackCursor
        if selectionChanged || voiceColorsChanged
            || documentChanged || cursorChanged {
            coord.hostingView?.rootView = rootView
            coord.lastSelection = selection
            coord.lastVoiceColors = voiceColors
            coord.lastDocumentSize = document.size
            coord.lastPlaybackCursor = playbackCursor
        }

        // Apply external magnification changes (e.g., sidebar reset
        // button) without clobbering a value we just reported. Skip
        // during live pinch — the gesture itself is driving
        // `nsView.magnification`, and writing it back from a
        // mid-gesture binding update would fight the gesture
        // handler (causing visible jitter / glitches at frame
        // boundaries).
        if !coord.isLiveMagnifying
            && abs(nsView.magnification - magnification) > 0.001 {
            nsView.magnification = magnification
        }

        // Programmatic scroll-to (auto-follow during playback).
        // The `pendingScrollTarget != lastHandledScrollTarget` check
        // makes this a one-shot per request: SwiftUI re-evaluates
        // this body on every body input change, so without the
        // guard we'd re-issue the animation each time.
        if let target = pendingScrollTarget,
           target != coord.lastHandledScrollTarget {
            coord.lastHandledScrollTarget = target
            let clipView = nsView.contentView
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                ctx.timingFunction = .init(name: .easeInEaseOut)
                ctx.allowsImplicitAnimation = true
                clipView.animator().setBoundsOrigin(target)
                nsView.reflectScrolledClipView(clipView)
            }, completionHandler: {
                DispatchQueue.main.async { pendingScrollTarget = nil }
            })
        } else if pendingScrollTarget == nil {
            coord.lastHandledScrollTarget = nil
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(contentInset: Self.contentInset)
    }

    final class Coordinator: NSObject {
        var contentInset: CGFloat
        var hostingView: NSHostingView<AnyView>?
        var magnificationBinding: Binding<CGFloat>?
        var documentScrollXBinding: Binding<CGFloat>?
        var documentScrollYBinding: Binding<CGFloat>?
        var onTap: ((CGPoint) -> Void)?
        /// Set while the user is actively pinching. The score's
        /// NSScrollView drives its own magnification via Core
        /// Animation; we mustn't write back to `nsView.magnification`
        /// while the gesture is in progress (it would fight the
        /// gesture handler), but we still want to mirror its current
        /// value into the SwiftUI binding so the sticky pane's
        /// scaleEffect tracks the score live.
        var isLiveMagnifying = false
        /// Last `pendingScrollTarget` value the coordinator has
        /// already animated to. Compared against the current binding
        /// in `updateNSView` so the same request isn't re-issued on
        /// every body re-eval.
        var lastHandledScrollTarget: CGPoint?
        /// KVO observation of `NSScrollView.magnification`. Active
        /// only between will-start and did-end live magnification —
        /// AppKit fires no "during" notification, so we observe the
        /// property directly to push live values into the SwiftUI
        /// binding at gesture frame rate.
        var magnificationObservation: NSKeyValueObservation?
        /// Last `rootView` inputs we actually applied. Used to skip
        /// the NSHostingView refresh when only the scroll binding
        /// changed (the common case during scroll / pinch).
        var lastSelection: ScoreSelection = .none
        var lastVoiceColors: [Int: Color] = [:]
        var lastDocumentSize: CGSize = .zero
        var lastPlaybackCursor: ScoreCursor?

        init(contentInset: CGFloat) {
            self.contentInset = contentInset
        }

        @objc func handleClick(_ gr: NSClickGestureRecognizer) {
            guard let hosting = hostingView else { return }
            let local = gr.location(in: hosting)
            // `.padding(inset)` shifts the ScoreView inside the
            // hosting view by (inset, inset); subtract it back out
            // to get coords in the document/ScoreView coord space.
            let docPoint = CGPoint(
                x: local.x - contentInset,
                y: local.y - contentInset)
            onTap?(docPoint)
        }

        @objc func willStartLiveMagnify(_ notification: Notification) {
            isLiveMagnifying = true
            // Observe the scroll view's magnification at gesture
            // frame rate so the sticky pane's scaleEffect can
            // track in lock-step. AppKit doesn't post a "during
            // live magnify" notification — KVO is the only
            // continuous signal available.
            guard let scrollView = notification.object as? NSScrollView
            else { return }
            magnificationObservation = scrollView.observe(
                \.magnification, options: [.new]
            ) { [weak self] _, change in
                guard let self, let value = change.newValue else { return }
                self.magnificationBinding?.wrappedValue = value
            }
        }

        @objc func magnificationDidEnd(_ notification: Notification) {
            isLiveMagnifying = false
            magnificationObservation = nil
            guard let scrollView = notification.object as? NSScrollView
            else { return }
            magnificationBinding?.wrappedValue = scrollView.magnification
            // Catch-up: any final bounds frame that landed on the
            // exact gesture-end boundary should be reflected in the
            // bindings.
            let bounds = scrollView.contentView.bounds
            documentScrollXBinding?.wrappedValue = bounds.origin.x
            documentScrollYBinding?.wrappedValue = bounds.origin.y
        }

        @objc func boundsDidChange(_ notification: Notification) {
            guard let clipView = notification.object as? NSClipView
            else { return }
            // Pass the raw clipView origin through, even when it
            // briefly slips below zero (over-scroll up / left) or
            // past the document end (over-scroll down / right).
            // The sticky pane needs to follow the elastic bounce so
            // it stays glued to the staves; clamping here would
            // make it freeze at the document edge instead. The
            // visibility check (`horizontalScrollX > 0`) and the
            // measure lookup (`max(0, …)`) absorb negative values
            // downstream without misbehaving.
            //
            // We let this fire during pinch as well: the sticky
            // needs to follow the magnify-anchor's scroll shift
            // live. Body re-evaluation stays cheap thanks to the
            // cached `measureContexts`, the rootView short-circuit
            // in `updateNSView`, and `_LayerBackedSystem`'s
            // identity check — the layer tree doesn't rebuild when
            // the synthetic system is structurally identical.
            documentScrollXBinding?.wrappedValue =
                clipView.bounds.origin.x
            documentScrollYBinding?.wrappedValue =
                clipView.bounds.origin.y
        }
    }
}
#endif
