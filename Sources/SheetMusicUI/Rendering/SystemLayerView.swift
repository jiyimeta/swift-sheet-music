import QuartzCore
import SheetMusicCore
import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// SwiftUI host for a CALayer-rendered system.  Replaces the old
/// `SystemCanvas` (SwiftUI `Canvas`, rasterised once at layout size)
/// with a layer tree that stays sharp at any zoom level.
///
/// The view reports a fixed frame of `system.size.width` ×
/// `system.size.height + 1` (the extra pixel matches the old overlap
/// that hid seams between stacked systems).
///
/// **Selection performance.** The host view caches the last
/// `LayoutSystem` it rendered: when SwiftUI re-invokes `updateNSView`
/// / `updateUIView` because `selection` changed but the layout is
/// unchanged, the expensive CALayer tree is reused as-is and only
/// the noteheads' / rests' `fillColor` is re-applied via
/// `ScoreLayerBuilder.applySelection`. The range box is a separate
/// overlay layer that is cleared and rebuilt on each selection
/// change. This keeps click-to-recolour work O(|previous ∪ new|)
/// instead of O(score size).
@available(macOS 15.0, iOS 16.0, *)
struct SystemLayerView: View {
    let system: LayoutSystem
    let metrics: StaffMetrics
    let selection: SelectionRenderState

    init(
        system: LayoutSystem,
        metrics: StaffMetrics,
        selection: SelectionRenderState = .empty
    ) {
        self.system = system
        self.metrics = metrics
        self.selection = selection
    }

    var body: some View {
        _LayerBackedSystem(
            system: system, metrics: metrics, selection: selection)
            .frame(
                width: system.size.width,
                height: system.size.height + 1,
                alignment: .topLeading)
    }
}

// MARK: - Platform-backed representable

#if os(macOS)
@available(macOS 15.0, *)
private struct _LayerBackedSystem: NSViewRepresentable {
    let system: LayoutSystem
    let metrics: StaffMetrics
    let selection: SelectionRenderState

    func makeNSView(context: Context) -> _LayerSystemHostView {
        let view = _LayerSystemHostView()
        view.configure(
            system: system, metrics: metrics, selection: selection)
        return view
    }

    func updateNSView(
        _ nsView: _LayerSystemHostView, context: Context
    ) {
        nsView.configure(
            system: system, metrics: metrics, selection: selection)
    }
}

@available(macOS 15.0, *)
private final class _LayerSystemHostView: NSView {
    // NOTE: We deliberately do NOT override `isFlipped` here.
    //
    // When a layer-backed NSView is `isFlipped = true`, AppKit
    // silently applies its own flip to the backing layer.  Stacking
    // our own flip on top caused content to render either above or
    // below the frame (upside-down).
    //
    // Instead we leave the backing layer in its native Y-up
    // orientation and flip the LayoutEngine's Y-down coordinates
    // exactly once via the root's `sublayerTransform` inside
    // `ScoreLayerBuilder`.  SwiftUI / NSHostingView still lays the
    // view out correctly because the NSView's own frame is set from
    // the outside via SwiftUI's `.frame(…)` modifier.

    private var lastSystem: LayoutSystem?
    private var lastMetrics: StaffMetrics?
    private var lastSelection: SelectionRenderState = .empty
    private var baseLayer: CALayer?
    private var overlayLayer: CALayer?
    private var itemLayers: [ScoreItemID: [CAShapeLayer]] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = CGColor(gray: 1, alpha: 1)
        layer?.masksToBounds = false
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(
        system: LayoutSystem,
        metrics: StaffMetrics,
        selection: SelectionRenderState
    ) {
        guard let hostLayer = layer else { return }
        let systemChanged = lastSystem != system || lastMetrics != metrics
        if systemChanged {
            hostLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            let result = ScoreLayerBuilder.buildSystemWithItems(
                system, metrics: metrics)
            hostLayer.addSublayer(result.root)

            let overlay = CALayer()
            overlay.frame = result.root.frame
            overlay.masksToBounds = false
            hostLayer.addSublayer(overlay)

            baseLayer = result.root
            overlayLayer = overlay
            itemLayers = result.items
            lastSystem = system
            lastMetrics = metrics
            // Re-apply the selection from a clean slate — the new
            // layers all start at `inkColor`.
            lastSelection = .empty
            setFrameSize(NSSize(
                width: system.size.width,
                height: system.size.height + 1))
        }
        applySelection(system: system, metrics: metrics, selection: selection)
        lastSelection = selection
    }

    private func applySelection(
        system: LayoutSystem,
        metrics: StaffMetrics,
        selection: SelectionRenderState
    ) {
        ScoreLayerBuilder.applySelection(
            items: itemLayers,
            previousSelection: lastSelection,
            newSelection: selection)
        overlayLayer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard selection.drawRangeBox, let overlay = overlayLayer else { return }
        ScoreLayerBuilder.drawRangeBoxes(
            system: system,
            selection: selection,
            metrics: metrics,
            height: system.size.height + 1,
            into: overlay)
    }
}

#else
@available(iOS 16.0, *)
private struct _LayerBackedSystem: UIViewRepresentable {
    let system: LayoutSystem
    let metrics: StaffMetrics
    let selection: SelectionRenderState

    func makeUIView(context: Context) -> _LayerSystemHostView {
        let view = _LayerSystemHostView()
        view.configure(
            system: system, metrics: metrics, selection: selection)
        return view
    }

    func updateUIView(
        _ uiView: _LayerSystemHostView, context: Context
    ) {
        uiView.configure(
            system: system, metrics: metrics, selection: selection)
    }
}

@available(iOS 16.0, *)
private final class _LayerSystemHostView: UIView {
    private var lastSystem: LayoutSystem?
    private var lastMetrics: StaffMetrics?
    private var lastSelection: SelectionRenderState = .empty
    private var baseLayer: CALayer?
    private var overlayLayer: CALayer?
    private var itemLayers: [ScoreItemID: [CAShapeLayer]] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(
        system: LayoutSystem,
        metrics: StaffMetrics,
        selection: SelectionRenderState
    ) {
        let systemChanged = lastSystem != system || lastMetrics != metrics
        if systemChanged {
            layer.sublayers?.forEach { $0.removeFromSuperlayer() }
            let result = ScoreLayerBuilder.buildSystemWithItems(
                system, metrics: metrics)
            layer.addSublayer(result.root)

            let overlay = CALayer()
            overlay.frame = result.root.frame
            overlay.masksToBounds = false
            layer.addSublayer(overlay)

            baseLayer = result.root
            overlayLayer = overlay
            itemLayers = result.items
            lastSystem = system
            lastMetrics = metrics
            lastSelection = .empty
            frame = CGRect(
                origin: frame.origin,
                size: CGSize(
                    width: system.size.width,
                    height: system.size.height + 1))
        }
        applySelection(system: system, metrics: metrics, selection: selection)
        lastSelection = selection
    }

    private func applySelection(
        system: LayoutSystem,
        metrics: StaffMetrics,
        selection: SelectionRenderState
    ) {
        ScoreLayerBuilder.applySelection(
            items: itemLayers,
            previousSelection: lastSelection,
            newSelection: selection)
        overlayLayer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard selection.drawRangeBox, let overlay = overlayLayer else { return }
        ScoreLayerBuilder.drawRangeBoxes(
            system: system,
            selection: selection,
            metrics: metrics,
            height: system.size.height + 1,
            into: overlay)
    }
}
#endif
