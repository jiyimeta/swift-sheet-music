import QuartzCore
import SheetMusicCore
import SheetMusicLayout

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

// Applies a `MeasureLayerDiffPlanner.Plan` to the live CALayer tree:
// rebuild only the measures whose drawn content changed, and merely
// slide the containers of measures that moved horizontally without
// otherwise changing. Split from `SystemLayerView.swift` (which stays
// under the file's own length cap) along the same seam as
// `ScoreLayerBuilder+MeasureContainer.swift`.

#if os(macOS)
    @available(macOS 15.0, *)
    extension LayerSystemHostView {
        /// Rebuild only the measures whose drawn content changed; slide
        /// the containers of measures that merely moved horizontally.
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
                if case let .reposition(newOriginX)? = plan.updates[measure.measureIndex] {
                    if let newOriginX,
                       let container = measureContainers[measure.measureIndex]
                    {
                        container.position = CGPoint(x: newOriginX, y: 0)
                    }
                    continue
                }
                removeMeasureLayer(at: measure.measureIndex)
                let built = ScoreLayerBuilder.buildMeasure(
                    measure, metrics: metrics, systemSize: systemSize,
                    showsInvisibleElements: system.showsInvisibleElements,
                )
                root.addSublayer(built.container)
                measureContainers[measure.measureIndex] = built.container
                measureItems[measure.measureIndex] = built.items
                for (id, layers) in built.items {
                    itemLayers[id, default: []].append(contentsOf: layers)
                }
                // A rebuilt measure's layers start at `inkColor`, so the
                // selection must be re-applied from scratch.
                lastSelection = .empty
            }
            for index in plan.removed {
                removeMeasureLayer(at: index)
            }
        }

        /// Removes a measure's container layer (if any) and detaches its
        /// selectable item layers from `itemLayers`. Shared by the
        /// rebuild branch above (which drops the stale container before
        /// replacing it) and the trailing pass that removes measures no
        /// longer present in the system.
        private func removeMeasureLayer(at index: Int) {
            measureContainers[index]?.removeFromSuperlayer()
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
        }
    }
#else
    extension LayerSystemHostView {
        /// Rebuild only the measures whose drawn content changed; slide
        /// the containers of measures that merely moved horizontally.
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
                if case let .reposition(newOriginX)? = plan.updates[measure.measureIndex] {
                    if let newOriginX,
                       let container = measureContainers[measure.measureIndex]
                    {
                        container.position = CGPoint(x: newOriginX, y: 0)
                    }
                    continue
                }
                removeMeasureLayer(at: measure.measureIndex)
                let built = ScoreLayerBuilder.buildMeasure(
                    measure, metrics: metrics, systemSize: systemSize,
                    showsInvisibleElements: system.showsInvisibleElements,
                )
                root.addSublayer(built.container)
                measureContainers[measure.measureIndex] = built.container
                measureItems[measure.measureIndex] = built.items
                for (id, layers) in built.items {
                    itemLayers[id, default: []].append(contentsOf: layers)
                }
                // A rebuilt measure's layers start at `inkColor`, so the
                // selection must be re-applied from scratch.
                lastSelection = .empty
            }
            for index in plan.removed {
                removeMeasureLayer(at: index)
            }
        }

        /// Removes a measure's container layer (if any) and detaches its
        /// selectable item layers from `itemLayers`. Shared by the
        /// rebuild branch above (which drops the stale container before
        /// replacing it) and the trailing pass that removes measures no
        /// longer present in the system.
        private func removeMeasureLayer(at index: Int) {
            measureContainers[index]?.removeFromSuperlayer()
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
        }
    }
#endif
