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
    /// Ink color for all strokes / fills.  Matches the prior
    /// `.environment(\.colorScheme, .light)` + `.color(.primary)`
    /// combination — always black on white.
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

    /// Builds the base layer tree and returns both the root CALayer
    /// and a dictionary mapping each selectable `ScoreItemID` to the
    /// CAShapeLayers that must be re-tinted when the selection
    /// changes.
    ///
    /// The tree is always drawn in `inkColor` — selection coloring
    /// is applied afterwards via `applySelection(...)` so that a
    /// selection change does not force a full layer rebuild.
    static func buildSystemWithItems(
        _ system: LayoutSystem,
        metrics: StaffMetrics,
    ) -> (root: CALayer, items: [ScoreItemID: [CAShapeLayer]]) {
        let root = CALayer()
        let height = system.size.height + 1
        root.frame = CGRect(
            origin: .zero,
            size: CGSize(width: system.size.width, height: height),
        )
        root.masksToBounds = false
        root.backgroundColor = CGColor(gray: 1, alpha: 1)

        drawStaves(system: system, metrics: metrics, height: height, into: root)
        drawSystemBar(system: system, metrics: metrics, height: height, into: root)
        drawBrackets(system: system, metrics: metrics, height: height, into: root)
        drawPartLabels(system: system, metrics: metrics, height: height, into: root)

        var ctx = BuildContext()
        ctx.showsInvisibleElements = system.showsInvisibleElements
        drawVisibleElements(
            system: system, metrics: metrics,
            height: height, context: &ctx, into: root,
        )
        // Routed-to-invisible chord/note glyphs already sit under a
        // 50% group opacity layer (see drawInvisibleElements); flip
        // the flag so per-note dispatch grays those noteheads rather
        // than skipping them.
        ctx.showsInvisibleElements = true
        drawInvisibleElements(
            system: system, metrics: metrics,
            height: height, context: &ctx, root: root,
        )
        return (root, ctx.items)
    }

    private static func drawVisibleElements(
        system: LayoutSystem, metrics: StaffMetrics,
        height: CGFloat, context ctx: inout BuildContext, into parent: CALayer,
    ) {
        for measure in system.measures {
            let base = CGPoint(x: measure.origin.x, y: measure.origin.y)
            for element in measure.elements {
                drawElement(element, base: base, metrics: metrics, height: height, context: &ctx, into: parent)
            }
            for el in measure.markers {
                drawElement(el, base: base, metrics: metrics, height: height, context: &ctx, into: parent)
            }
            for el in measure.jumps {
                drawElement(el, base: base, metrics: metrics, height: height, context: &ctx, into: parent)
            }
        }
        for el in system.spanners {
            drawElement(el, base: .zero, metrics: metrics, height: height, context: &ctx, into: parent)
        }
    }

    /// Builds invisible elements into a half-opacity sublayer.
    /// MuseScore invisibleColor() = #808080; 50% black on white is the exact equivalent.
    private static func drawInvisibleElements(
        system: LayoutSystem, metrics: StaffMetrics,
        height: CGFloat, context ctx: inout BuildContext, root: CALayer,
    ) {
        let hasInvisible = system.measures.contains { !$0.invisibleElements.isEmpty }
            || !system.invisibleSpanners.isEmpty
        guard hasInvisible else { return }
        let invisibleLayer = CALayer()
        invisibleLayer.frame = root.bounds
        invisibleLayer.opacity = 0.5
        invisibleLayer.masksToBounds = false
        for measure in system.measures where !measure.invisibleElements.isEmpty {
            let base = CGPoint(x: measure.origin.x, y: measure.origin.y)
            for element in measure.invisibleElements {
                drawElement(element, base: base, metrics: metrics, height: height, context: &ctx, into: invisibleLayer)
            }
        }
        for el in system.invisibleSpanners {
            drawElement(el, base: .zero, metrics: metrics, height: height, context: &ctx, into: invisibleLayer)
        }
        root.addSublayer(invisibleLayer)
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
            items[id, default: []].append(layer)
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
                if layer.fillColor != nil {
                    layer.fillColor = inkColor
                }
                if layer.strokeColor != nil {
                    layer.strokeColor = inkColor
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
