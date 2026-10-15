import QuartzCore
import SheetMusicCore
import SheetMusicLayout

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// The subset of `LayerSystemHostView`'s (macOS `NSView` / iOS `UIView`)
/// stored state that `applyMeasureDiff` and `remount` read and mutate.
/// The macOS and iOS host views are otherwise unrelated types (`NSView`
/// vs. `UIView` subclasses cannot share a common base class), so this
/// protocol plus a single default-implementation extension is how the two
/// platforms share one copy of the diff-application logic instead of two
/// byte-identical copies drifting apart (Task 8 review finding 5 —
/// this module already has one recorded Canvas/CALayer drift incident).
@MainActor
protocol MeasureDiffHosting: AnyObject {
    var baseLayer: CALayer? { get }
    var itemLayers: [ScoreItemID: [CAShapeLayer]] { get set }
    var measureContainers: [Int: CALayer] { get set }
    var measureItems: [Int: [ScoreItemID: [CAShapeLayer]]] { get set }
    /// The system-local X range the mounted measures and spanners were
    /// chosen by — `nil` when every one of them is mounted.
    var mountedRange: ClosedRange<CGFloat>? { get set }
    /// Mounted system-level spanners, by index in `LayoutSystem.spanners`.
    var spannerLayers: [Int: MountedLayers] { get set }
    /// The shared hidden-element group, when anything mounted has one.
    var invisibleLayers: MountedLayers? { get set }
    var invisibleMembership: InvisibleMembership { get set }
}

@available(macOS 15.0, *)
extension MeasureDiffHosting {
    /// Takes over the bookkeeping of a tree `ScoreLayerBuilder` just built
    /// for `range` — everything except `baseLayer`, which the host view
    /// owns and sets itself.
    func adopt(_ built: ScoreLayerBuilder.SystemLayers, range: ClosedRange<CGFloat>?) {
        itemLayers = built.items
        measureContainers = built.measureContainers
        measureItems = built.measureItems
        spannerLayers = built.spanners
        invisibleLayers = built.invisible
        invisibleMembership = built.invisibleMembership
        mountedRange = range
    }

    /// Rebuild only the measures whose drawn content changed; slide the
    /// containers of measures that merely moved horizontally.
    ///
    /// Only the measures that meet `mountedRange` are touched: one that no
    /// longer does is unmounted, and one that slid into it is built like a
    /// new measure. The caller updates `mountedRange` first and calls
    /// `remount` afterwards for the system-level spanners and hidden
    /// elements, which this does not handle.
    ///
    /// Deliberately does not touch `lastSelection`. `configure` calls
    /// `applySelection` right after this returns, and
    /// `ScoreLayerBuilder.applySelection` computes
    /// `toReset = previousSelection.selectedIDs - newSelection.selectedIDs`
    /// then unconditionally re-tints every ID in `newSelection` — both
    /// steps are correct whether or not a given measure was just
    /// rebuilt: a rebuilt measure's fresh layers already start at
    /// `inkColor`, so resetting an ID that happens to fall in `toReset`
    /// is a harmless no-op, and an ID in `newSelection` gets tinted
    /// regardless of which measure (rebuilt or not) it lives in.
    /// Zeroing `lastSelection` here — as an earlier version of this
    /// function did — corrupts `toReset` for every OTHER, non-rebuilt
    /// measure: a note selected before this edit but not touched by it
    /// would never get reset, staying tinted forever (Task 8 review
    /// finding 1). `rebuildAll` is different and must keep resetting
    /// `lastSelection` to `.empty`: there, every layer (in every
    /// measure) is new, so there is no "other, non-rebuilt measure" to
    /// protect.
    func applyMeasureDiff(
        previous: LayoutSystem,
        system: LayoutSystem,
        metrics: StaffMetrics,
    ) {
        guard let root = baseLayer else { return }
        let systemSize = CGSize(
            width: system.size.width,
            height: system.size.height + 1,
        )
        let plan = MeasureLayerDiffPlanner.plan(previous: previous, system: system)

        // Disable implicit animation: a rebuilt or repositioned
        // measure must appear in the same frame, not fade / slide in.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        for (position, measure) in system.measures.enumerated() {
            guard SystemMount.meets(measure, mountedRange) else {
                if measureContainers[measure.measureIndex] != nil {
                    removeMeasureLayer(at: measure.measureIndex)
                }
                continue
            }
            switch plan.updates[measure.measureIndex] {
            case let .reposition(newOriginX):
                if let container = measureContainers[measure.measureIndex] {
                    if let newOriginX {
                        container.position = CGPoint(x: newOriginX, y: 0)
                    }
                    continue
                }
                // With every measure mounted this is an invariant
                // violation (Task 8 review finding 8): the planner said
                // this measure only needs repositioning, which implies a
                // live container already exists for it. Fail loudly in
                // debug builds and recover by rebuilding below instead of
                // silently leaving a missing frame on screen. Mounted by
                // range, it is just a measure that slid into view.
                assert(
                    mountedRange != nil,
                    """
                    MeasureLayerDiffPlanner said .reposition for measure \
                    \(measure.measureIndex), but no live container exists \
                    for it. Falling back to rebuilding it.
                    """,
                )
            case .rebuild, nil:
                break
            }
            if measureContainers[measure.measureIndex] != nil {
                removeMeasureLayer(at: measure.measureIndex)
            }
            mountMeasure(measure, at: position, of: system, metrics: metrics, systemSize: systemSize, root: root)
        }
        for index in plan.removed {
            removeMeasureLayer(at: index)
        }
    }

    /// Mounts what `range` newly meets and unmounts what it no longer
    /// does — measures, system-level spanners and the hidden-element
    /// group — leaving everything that stays in view untouched.
    ///
    /// Selection tints are not applied here; `configure` calls
    /// `applySelection` next, which tints every selected item, freshly
    /// mounted ones included.
    func remount(system: LayoutSystem, metrics: StaffMetrics, to range: ClosedRange<CGFloat>?) {
        guard let root = baseLayer else { return }
        mountedRange = range
        let systemSize = CGSize(width: system.size.width, height: system.size.height + 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        for (position, measure) in system.measures.enumerated() {
            let isMounted = measureContainers[measure.measureIndex] != nil
            if SystemMount.meets(measure, range) {
                if !isMounted {
                    mountMeasure(
                        measure, at: position, of: system, metrics: metrics, systemSize: systemSize, root: root,
                    )
                }
            } else if isMounted {
                removeMeasureLayer(at: measure.measureIndex)
            }
        }

        for (index, spanner) in system.spanners.enumerated() {
            if SystemMount.meets(spanner: spanner, range) {
                guard spannerLayers[index] == nil else { continue }
                let built = ScoreLayerBuilder.buildSpanner(spanner, of: system, metrics: metrics)
                insert(built.layers, below: anchor(afterSpanner: index, count: system.spanners.count), into: root)
                spannerLayers[index] = built
                attachItems(built.items)
            } else if let mounted = spannerLayers[index] {
                mounted.layers.forEach { $0.removeFromSuperlayer() }
                detachItems(mounted.items)
                spannerLayers[index] = nil
            }
        }

        // One group for every hidden element, so it is rebuilt whole —
        // and only when what it should hold changed.
        let membership = InvisibleMembership(system: system, visibleXRange: range)
        guard membership != invisibleMembership else { return }
        if let old = invisibleLayers {
            old.layers.forEach { $0.removeFromSuperlayer() }
            detachItems(old.items)
        }
        let built = ScoreLayerBuilder.buildInvisibleGroup(system, membership: membership, metrics: metrics)
        if let built {
            // Always topmost, as `buildSystemWithItems` draws it.
            built.layers.forEach(root.addSublayer)
            attachItems(built.items)
        }
        invisibleLayers = built
        invisibleMembership = membership
    }

    /// Builds `measure` (at `position` in `system.measures`) and puts its
    /// container in its z-order slot.
    private func mountMeasure(
        _ measure: LayoutMeasure, at position: Int, of system: LayoutSystem,
        metrics: StaffMetrics, systemSize: CGSize, root: CALayer,
    ) {
        let built = ScoreLayerBuilder.buildMeasure(
            measure, metrics: metrics, systemSize: systemSize,
            showsInvisibleElements: system.showsInvisibleElements,
        )
        insert([built.container], below: anchor(afterMeasureAt: position, of: system), into: root)
        measureContainers[measure.measureIndex] = built.container
        measureItems[measure.measureIndex] = built.items
        attachItems(built.items)
    }

    /// The layer whatever is mounted for the measure at `position` goes
    /// below, to keep `buildSystemWithItems`' order — measures in order,
    /// then spanners, then the hidden-element group: the next mounted
    /// measure's container, or failing that the first mounted spanner,
    /// or the group. `nil` puts it on top.
    ///
    /// Preserving that order is what keeps a rebuilt measure out from on
    /// top of the system spanners, the hidden-element group and later
    /// measures (Task 8 review finding 2).
    private func anchor(afterMeasureAt position: Int, of system: LayoutSystem) -> CALayer? {
        for measure in system.measures[(position + 1)...] {
            if let container = measureContainers[measure.measureIndex] {
                return container
            }
        }
        return anchor(afterSpanner: -1, count: system.spanners.count)
    }

    /// `anchor(afterMeasureAt:of:)` for the spanner at `index`.
    private func anchor(afterSpanner index: Int, count: Int) -> CALayer? {
        for next in (index + 1) ..< max(index + 1, count) {
            if let first = spannerLayers[next]?.layers.first {
                return first
            }
        }
        return invisibleLayers?.layers.first
    }

    private func insert(_ layers: [CALayer], below anchor: CALayer?, into root: CALayer) {
        for layer in layers {
            if let anchor {
                root.insertSublayer(layer, below: anchor)
            } else {
                root.addSublayer(layer)
            }
        }
    }

    private func attachItems(_ items: [ScoreItemID: [CAShapeLayer]]) {
        for (id, layers) in items {
            itemLayers[id, default: []].append(contentsOf: layers)
        }
    }

    private func detachItems(_ items: [ScoreItemID: [CAShapeLayer]]) {
        for (id, layers) in items {
            itemLayers[id]?.removeAll { stale in
                layers.contains { $0 === stale }
            }
            if itemLayers[id]?.isEmpty == true {
                itemLayers[id] = nil
            }
        }
    }

    /// Removes a measure's container layer (if any) and detaches its
    /// selectable item layers from `itemLayers`. Shared by the rebuild
    /// branch of `applyMeasureDiff` (which drops the stale container
    /// before replacing it), its trailing pass that removes measures no
    /// longer present in the system, and `remount`.
    private func removeMeasureLayer(at index: Int) {
        measureContainers[index]?.removeFromSuperlayer()
        detachItems(measureItems[index] ?? [:])
        measureContainers[index] = nil
        measureItems[index] = nil
    }
}

#if os(macOS)
    @available(macOS 15.0, *)
    extension LayerSystemHostView: MeasureDiffHosting {}
#else
    extension LayerSystemHostView: MeasureDiffHosting {}
#endif
