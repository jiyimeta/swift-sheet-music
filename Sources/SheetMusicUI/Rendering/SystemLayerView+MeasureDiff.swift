import QuartzCore
import SheetMusicCore
import SheetMusicLayout

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// The subset of `LayerSystemHostView`'s (macOS `NSView` / iOS `UIView`)
/// stored state that `applyMeasureDiff` reads and mutates. The macOS and
/// iOS host views are otherwise unrelated types (`NSView` vs. `UIView`
/// subclasses cannot share a common base class), so this protocol plus a
/// single default-implementation extension is how the two platforms
/// share one copy of the diff-application logic instead of two
/// byte-identical copies drifting apart (Task 8 review finding 5 —
/// this module already has one recorded Canvas/CALayer drift incident).
@MainActor
protocol MeasureDiffHosting: AnyObject {
    var baseLayer: CALayer? { get }
    var itemLayers: [ScoreItemID: [CAShapeLayer]] { get set }
    var measureContainers: [Int: CALayer] { get set }
    var measureItems: [Int: [ScoreItemID: [CAShapeLayer]]] { get set }
}

@available(macOS 15.0, *)
extension MeasureDiffHosting {
    /// Rebuild only the measures whose drawn content changed; slide the
    /// containers of measures that merely moved horizontally.
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

        for measure in system.measures {
            switch plan.updates[measure.measureIndex] {
            case let .reposition(newOriginX):
                if let container = measureContainers[measure.measureIndex] {
                    if let newOriginX {
                        container.position = CGPoint(x: newOriginX, y: 0)
                    }
                    continue
                }
                // Invariant violation (Task 8 review finding 8): the
                // planner said this measure only needs repositioning,
                // which implies a live container already exists for it
                // — but it doesn't. `measureContainers` is supposed to
                // stay in lockstep with `previous.measures` always, so
                // this should be unreachable; fail loudly in debug
                // builds and recover by rebuilding below instead of
                // silently leaving a stale or missing frame on screen.
                assertionFailure(
                    """
                    MeasureLayerDiffPlanner said .reposition for measure \
                    \(measure.measureIndex), but no live container exists \
                    for it. Falling back to rebuilding it.
                    """,
                )
            case .rebuild, nil:
                break
            }
            // Preserve z-order: a rebuilt measure must land back at the
            // sublayer index its predecessor occupied, not appended on
            // top of the system spanners / invisible-elements layer /
            // later measures that `buildSystemWithItems` draws after
            // the measure containers (Task 8 review finding 2).
            let insertionIndex = removeMeasureLayer(at: measure.measureIndex, root: root)
            let built = ScoreLayerBuilder.buildMeasure(
                measure, metrics: metrics, systemSize: systemSize,
                showsInvisibleElements: system.showsInvisibleElements,
            )
            if let insertionIndex, insertionIndex <= (root.sublayers?.count ?? 0) {
                root.insertSublayer(built.container, at: UInt32(insertionIndex))
            } else {
                root.addSublayer(built.container)
            }
            measureContainers[measure.measureIndex] = built.container
            measureItems[measure.measureIndex] = built.items
            for (id, layers) in built.items {
                itemLayers[id, default: []].append(contentsOf: layers)
            }
        }
        for index in plan.removed {
            removeMeasureLayer(at: index, root: root)
        }
    }

    /// Removes a measure's container layer (if any) and detaches its
    /// selectable item layers from `itemLayers`. Shared by the rebuild
    /// branch above (which drops the stale container before replacing
    /// it) and the trailing pass that removes measures no longer
    /// present in the system.
    ///
    /// Returns the sublayer index the container occupied in
    /// `root.sublayers` immediately before removal (`nil` if there was
    /// no existing container), so a rebuild can reinsert its
    /// replacement at that same position instead of appending it on
    /// top of everything else.
    @discardableResult
    private func removeMeasureLayer(at index: Int, root: CALayer) -> Int? {
        let container = measureContainers[index]
        let sublayerIndex = container.flatMap { c in
            root.sublayers?.firstIndex { $0 === c }
        }
        container?.removeFromSuperlayer()
        for (id, layers) in measureItems[index] ?? [:] {
            itemLayers[id]?.removeAll { stale in
                layers.contains { $0 === stale }
            }
            if itemLayers[id]?.isEmpty == true {
                itemLayers[id] = nil
            }
        }
        measureContainers[index] = nil
        measureItems[index] = nil
        return sublayerIndex
    }
}

#if os(macOS)
    @available(macOS 15.0, *)
    extension LayerSystemHostView: MeasureDiffHosting {}
#else
    extension LayerSystemHostView: MeasureDiffHosting {}
#endif
