import CoreGraphics
import SheetMusicLayout

/// Pure decision logic for `SystemLayerView`'s incremental measure
/// update: given the previously-rendered system and the new one, decide
/// which measure containers can be repositioned in place and which must
/// be rebuilt from scratch.
///
/// Deliberately free of `CALayer` / `AppKit` / `UIKit` so it can be
/// tested directly (`@testable import SheetMusicUI`) without a live
/// `NSView` / `UIView` host. The golden-PNG proof only exercises the
/// full-rebuild path (there is no rasterized fixture for an incremental
/// update), so this planner's own tests are the sole automated coverage
/// for the diff decision itself.
///
/// Assumes the caller keeps `measureContainers` / `measureItems` in a
/// 1:1 bijection with `previous.measures` (which `SystemLayerView`'s
/// host views do, by construction: `rebuildAll` repopulates both
/// together, and the trailing removal pass in `applyMeasureDiff` drops
/// both together). Given that invariant, whether a measure index has a
/// live container is equivalent to whether it's present in
/// `previous.measures`, so this planner only needs the two
/// `LayoutSystem` values, not the container dictionary itself.
enum MeasureLayerDiffPlanner {
    /// What a measure's container layer needs, given its previous render.
    enum Action: Equatable {
        /// Content is identical to the previous render; move the
        /// container's `position.x` to `newOriginX` if it changed
        /// (`nil` when the measure didn't move at all).
        case reposition(newOriginX: CGFloat?)
        /// Content changed, or the measure is new to this system — the
        /// container must be rebuilt via `ScoreLayerBuilder.buildMeasure`.
        case rebuild
    }

    /// The full set of per-measure actions for one `configure` call.
    struct Plan: Equatable {
        /// One entry per measure in the new system, keyed by
        /// `LayoutMeasure.measureIndex`.
        var updates: [Int: Action]
        /// `measureIndex` values present in `previous` but absent from
        /// the new system — their containers must be removed. A `Set`
        /// (not an `Array`) because it's built from a dictionary's
        /// `keys`, whose iteration order isn't guaranteed — an `Array`
        /// here would make `Plan` equality (and any future ordered
        /// consumer) nondeterministic across runs (Task 8 review
        /// finding 7).
        var removed: Set<Int>
    }

    /// Computes the plan for moving from `previous` to `system`.
    ///
    /// Callers are expected to have already established
    /// `systemFrameIsUnchanged(previous, system)` — this only decides
    /// the per-measure actions; it does not itself gate whether a full
    /// system rebuild is required instead of a measure-level diff.
    static func plan(previous: LayoutSystem, system: LayoutSystem) -> Plan {
        var previousByIndex: [Int: LayoutMeasure] = [:]
        for m in previous.measures {
            previousByIndex[m.measureIndex] = m
        }

        var updates: [Int: Action] = [:]
        var liveIndices: Set<Int> = []
        for measure in system.measures {
            liveIndices.insert(measure.measureIndex)
            if let old = previousByIndex[measure.measureIndex],
               old.hasSameRenderContent(as: measure)
            {
                let newOriginX = old.origin.x != measure.origin.x
                    ? measure.origin.x : nil
                updates[measure.measureIndex] = .reposition(newOriginX: newOriginX)
            } else {
                updates[measure.measureIndex] = .rebuild
            }
        }
        let removed = Set(previousByIndex.keys).subtracting(liveIndices)
        return Plan(updates: updates, removed: removed)
    }

    /// True when everything drawn outside the per-measure containers is
    /// identical between two systems, so a measure-level diff (rather
    /// than a full rebuild) is sufficient.
    ///
    /// Deliberately includes each measure's `invisibleElements`: those
    /// are drawn into one shared system-level 50%-opacity layer (not a
    /// per-measure container), so overlapping hidden elements composite
    /// correctly — a change there needs the full rebuild path. Because
    /// that shared layer positions each measure's hidden elements at
    /// ABSOLUTE system X, the check also has to cover a pure horizontal
    /// shift; see `invisibleLayerIsUnchanged`.
    ///
    /// Also compares `BarLineGeometry.staffLineEndX(for:)`: `drawStaves`
    /// (via `StaffRenderer.endX(for:)`) clips the staff lines to
    /// that X, which is derived from the LAST measure's `origin.x` and
    /// its trailing barline's subtype (`LayoutSystem.trailingBarLine`)
    /// — a system-level draw input that lives outside every measure
    /// container, same trap category as `invisibleElements`. Reachable
    /// in `wrapToViewWidth` mode: `size` stays equal across an edit that
    /// only changes the last measure's barline subtype (e.g. it becomes
    /// the new last measure and gains an `end` barline), which would
    /// otherwise pass this predicate, diff only that measure, and leave
    /// the staff lines up to ~0.5 sp short of the new barline glyph
    /// (Task 8 review finding 3).
    static func systemFrameIsUnchanged(
        _ a: LayoutSystem, _ b: LayoutSystem,
    ) -> Bool {
        a.size == b.size
            && a.origin == b.origin
            && a.staffOrigins == b.staffOrigins
            && a.staffAddresses == b.staffAddresses
            && a.partLabels == b.partLabels
            && a.brackets == b.brackets
            && a.spanners == b.spanners
            && a.invisibleSpanners == b.invisibleSpanners
            && a.sp == b.sp
            && a.showsInvisibleElements == b.showsInvisibleElements
            && invisibleLayerIsUnchanged(a, b)
            && BarLineGeometry.staffLineEndX(for: a)
            == BarLineGeometry.staffLineEndX(for: b)
    }

    /// True when the shared system-level invisible-elements layer would
    /// draw identically for `a` and `b`.
    ///
    /// Two separate reasons it can differ, and the second is the subtle
    /// one:
    ///
    /// 1. The hidden elements themselves changed. `invisibleElements` is
    ///    measure-relative, so comparing the per-measure arrays covers
    ///    that.
    /// 2. A measure merely SLID SIDEWAYS.
    ///    `ScoreLayerBuilder.drawInvisibleElements` draws every measure's
    ///    hidden elements into one shared 50 %-opacity layer at
    ///    `base = (measure.origin.x, measure.origin.y)` — absolute system
    ///    X, not a per-measure container. But `invisibleElements` is
    ///    measure-relative and `LayoutMeasure.hasSameRenderContent`
    ///    deliberately ignores `origin.x`, so a measure that only moved
    ///    horizontally takes `.reposition`: its own container slides while
    ///    its contribution to the shared invisible layer stays at the old
    ///    X. Reachable in `wrapToViewWidth` mode with
    ///    `showsInvisibleElements` on — `stretchWidths` can redistribute
    ///    space after an edit so that `size`, `staffOrigins`, `spanners`
    ///    and `staffLineEndX` all stay equal while the middle measures
    ///    move.
    ///
    /// The `origin.x` requirement is scoped to systems that actually have
    /// hidden measure content, so the common case (`showsInvisibleElements`
    /// off ⇒ every `invisibleElements` empty) keeps taking the cheap
    /// measure-level diff. `invisibleSpanners` need no such guard: they are
    /// drawn at `base == .zero`, so a measure sliding cannot strand them.
    private static func invisibleLayerIsUnchanged(
        _ a: LayoutSystem, _ b: LayoutSystem,
    ) -> Bool {
        guard a.measures.map(\.invisibleElements)
            == b.measures.map(\.invisibleElements)
        else { return false }
        let hasHiddenMeasureContent = a.measures.contains {
            !$0.invisibleElements.isEmpty
        }
        guard hasHiddenMeasureContent else { return true }
        return a.measures.map(\.origin.x) == b.measures.map(\.origin.x)
    }
}
