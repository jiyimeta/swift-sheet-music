import QuartzCore
import SheetMusicCore
import SheetMusicLayout

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// Builds a `CALayer` tree from a `LayoutSystem`.
///
/// Each element of the score becomes its own `CAShapeLayer` (or small
/// group of layers) with a resolution-independent `CGPath`, so the
/// content stays sharp at any zoom level — unlike the older
/// `Canvas`-based renderer which rasterised once at layout size.
///
/// Glyphs (Bravura SMuFL + system-font expression text) are rendered
/// via paths extracted with `CTFontCreatePathForGlyph`, so they are
/// genuine vectors at every zoom.
///
/// LayoutEngine emits Y-down coordinates (y increases downward from
/// the system's top).  On macOS, CALayer uses Y-up by default, so we
/// flip every path's Y at construction time via a helper
/// (`flipForPlatform`).  On iOS, `UIView.layer` is already Y-down and
/// no flip is applied.
@available(macOS 15.0, *)
public enum ScoreLayerBuilder {
    /// Default ink color for strokes / fills of elements without an
    /// author color.  Matches the prior
    /// `.environment(\.colorScheme, .light)` + `.color(.primary)`
    /// combination — black on white.  Author `<color>` overrides are
    /// applied per element via `scoreColorToCGColor` below.
    static let inkColor: CGColor = .init(gray: 0, alpha: 1)

    /// Convert MuseScore's RGBA score color into a `CGColor`. Used
    /// for `.staffText` (and any future author-colored element) so
    /// the renderer can honor `<color>` attributes from `.mscx`.
    static func scoreColorToCGColor(
        _ color: ScoreColor,
    ) -> CGColor {
        CGColor(
            red: CGFloat(color.red) / 255,
            green: CGFloat(color.green) / 255,
            blue: CGFloat(color.blue) / 255,
            alpha: CGFloat(color.alpha) / 255,
        )
    }

    // MARK: - Entry point

    public static func buildSystem(
        _ system: LayoutSystem,
        metrics: StaffMetrics,
    ) -> CALayer {
        buildSystemWithItems(system, metrics: metrics).root
    }

    /// A built system's layer tree, split so a host view can rebuild
    /// individual measures and mount the parts of a long system as they
    /// scroll into view.
    ///
    /// `measureContainers` are keyed by `LayoutMeasure.measureIndex`.
    /// Each has `anchorPoint == .zero`, `bounds` spanning the whole
    /// system, and `position.x == measure.origin.x`, so its children can
    /// be drawn in system coordinates with the X offset excluded — which
    /// is what lets a pure horizontal shift become a `position` write.
    ///
    /// Built for a `visibleXRange`, the tree holds only what meets it:
    /// the measures in `measureContainers`, the system-level spanners in
    /// `spanners`, and the hidden elements of both in `invisible`. Built
    /// for `nil`, it holds everything, in the same order.
    struct SystemLayers {
        let root: CALayer
        let measureContainers: [Int: CALayer]
        let measureItems: [Int: [ScoreItemID: [CAShapeLayer]]]
        /// Keyed by the spanner's index in `LayoutSystem.spanners`.
        let spanners: [Int: MountedLayers]
        /// The shared half-opacity group of hidden elements, or `nil`
        /// when nothing mounted has any.
        let invisible: MountedLayers?
        /// What `invisible` was drawn from.
        let invisibleMembership: InvisibleMembership
        let items: [ScoreItemID: [CAShapeLayer]]
    }

    /// Builds the base layer tree and returns the root CALayer, the
    /// per-measure container layers, and dictionaries mapping each
    /// selectable `ScoreItemID` to the CAShapeLayers that must be
    /// re-tinted when the selection changes.
    ///
    /// The tree is drawn in `inkColor` by default; elements carrying
    /// an author `<color>` override are tinted individually.
    /// Selection coloring is applied afterwards via
    /// `applySelection(...)` so that a selection change does not
    /// force a full layer rebuild.
    ///
    /// `visibleXRange`, in system-local X, limits the measures and
    /// spanners drawn to those that meet it (see `SystemMount`); the
    /// staves, brackets and labels are always drawn. `nil` draws all.
    static func buildSystemWithItems(
        _ system: LayoutSystem,
        metrics: StaffMetrics,
        visibleXRange: ClosedRange<CGFloat>? = nil,
    ) -> SystemLayers {
        let root = CALayer()
        let height = system.size.height + 1
        let systemSize = CGSize(width: system.size.width, height: height)
        root.frame = CGRect(origin: .zero, size: systemSize)
        root.masksToBounds = false
        root.backgroundColor = CGColor(gray: 1, alpha: 1)

        drawStaves(system: system, metrics: metrics, height: height, into: root)
        drawSystemBar(system: system, metrics: metrics, height: height, into: root)
        drawBrackets(system: system, metrics: metrics, height: height, into: root)
        // The labels' layers live on the root with the staves, so they survive a measure-level diff, and their
        // items join the system's own map (`itemLayers`) rather than any measure's.
        let labelItems = drawPartLabels(system: system, metrics: metrics, height: height, into: root)

        var containers: [Int: CALayer] = [:]
        var perMeasureItems: [Int: [ScoreItemID: [CAShapeLayer]]] = [:]
        var allItems = labelItems
        for measure in system.measures where SystemMount.meets(measure, visibleXRange) {
            let built = buildMeasure(
                measure, metrics: metrics, systemSize: systemSize,
                showsInvisibleElements: system.showsInvisibleElements,
            )
            root.addSublayer(built.container)
            containers[measure.measureIndex] = built.container
            perMeasureItems[measure.measureIndex] = built.items
            allItems.merge(built.items) { $0 + $1 }
        }

        // System-level spanners draw after every measure, as before.
        var spanners: [Int: MountedLayers] = [:]
        for (index, spanner) in system.spanners.enumerated()
            where SystemMount.meets(spanner: spanner, visibleXRange)
        {
            let mounted = buildSpanner(spanner, of: system, metrics: metrics)
            mounted.layers.forEach(root.addSublayer)
            spanners[index] = mounted
            allItems.merge(mounted.items) { $0 + $1 }
        }

        let membership = InvisibleMembership(system: system, visibleXRange: visibleXRange)
        let invisible = buildInvisibleGroup(system, membership: membership, metrics: metrics)
        if let invisible {
            invisible.layers.forEach(root.addSublayer)
            allItems.merge(invisible.items) { $0 + $1 }
        }

        return SystemLayers(
            root: root,
            measureContainers: containers,
            measureItems: perMeasureItems,
            spanners: spanners,
            invisible: invisible,
            invisibleMembership: membership,
            items: allItems,
        )
    }

    /// Context threaded through draw calls to collect the layers that
    /// the selection renderer will later re-tint.
    ///
    /// `showsInvisibleElements` mirrors `LayoutSystem.showsInvisibleElements`
    /// for the current build pass. Per-note dispatch in
    /// `ScoreLayerBuilder+Chord.drawChord` reads it to decide whether
    /// a hidden notehead should be grayed (50 %) or skipped outright.
    /// Stem / beam / ledger geometry uses the full note list either
    /// way (spec §6).
    struct BuildContext {
        var items: [ScoreItemID: [CAShapeLayer]] = [:]
        var showsInvisibleElements = false

        mutating func attach(
            _ layer: CAShapeLayer, to id: ScoreItemID,
        ) {
            BaseInk.remember(on: layer)
            items[id, default: []].append(layer)
        }
    }

    /// The ink a selectable layer was built with, remembered on the layer itself the moment it becomes
    /// selectable, so `applySelection` can undo a tint exactly instead of assuming the layer was black.
    ///
    /// Author `<color>` overrides make that assumption wrong: a red lyric, a colored notehead or a colored
    /// rehearsal mark reset to `inkColor` would come back from a selection permanently black. MuseScore has
    /// the same rule — `EngravingItem::curColor` returns the item's own `normalColor` when it is not
    /// selected, never a default (`dom/engravingitem.cpp`).
    ///
    /// It rides on the layer through `CALayer`'s undefined-key storage rather than in a parallel dictionary
    /// because the layer maps are rebuilt per measure by the diff planner, and a side table keyed by layer
    /// identity would have to be kept in step with every one of those rebuilds.
    final class BaseInk: NSObject {
        static let key = "sheetMusicBaseInk"

        let fill: CGColor?
        let stroke: CGColor?

        init(fill: CGColor?, stroke: CGColor?) {
            self.fill = fill
            self.stroke = stroke
            super.init()
        }

        /// Records `layer`'s current fill / stroke, once. Re-attaching the same layer (a notehead is
        /// attached twice — head and accidental — and a harmony once per run) must not overwrite a record
        /// made before a tint was applied.
        static func remember(on layer: CAShapeLayer) {
            guard layer.value(forKey: key) == nil else { return }
            layer.setValue(
                BaseInk(fill: layer.fillColor, stroke: layer.strokeColor),
                forKey: key,
            )
        }

        /// The ink `layer` was built with, or `nil` when it was never attached.
        static func of(_ layer: CAShapeLayer) -> BaseInk? {
            layer.value(forKey: key) as? BaseInk
        }
    }

    /// Re-tints the already-built `items` so they reflect
    /// `newSelection`. Layers previously tinted for `previousSelection`
    /// are reset to `inkColor`; layers for the new selection pick up
    /// their voice color.
    ///
    /// Work is O(|previous ∪ new|), not O(score size), so selection
    /// changes stay cheap regardless of how large the score is.
    static func applySelection(
        items: [ScoreItemID: [CAShapeLayer]],
        previousSelection: SelectionRenderState,
        newSelection: SelectionRenderState,
    ) {
        let toReset = previousSelection.selectedIDs
            .subtracting(newSelection.selectedIDs)
        for id in toReset {
            guard let layers = items[id] else { continue }
            for layer in layers {
                // Notehead / text glyphs are filled paths; bracket
                // hooks and segments are stroked. Resetting both
                // covers either kind without needing to know which.
                // The ink is the layer's own, recorded at `attach`
                // — see `BaseInk` for why not `inkColor`.
                let base = BaseInk.of(layer)
                if layer.fillColor != nil {
                    layer.fillColor = base?.fill ?? inkColor
                }
                if layer.strokeColor != nil {
                    layer.strokeColor = base?.stroke ?? inkColor
                }
            }
        }
        for id in newSelection.selectedIDs {
            guard let layers = items[id] else { continue }
            let color = newSelection.voiceColors[id.voiceIndex] ?? inkColor
            for layer in layers {
                if layer.fillColor != nil {
                    layer.fillColor = color
                }
                if layer.strokeColor != nil {
                    layer.strokeColor = color
                }
            }
        }
    }
}
