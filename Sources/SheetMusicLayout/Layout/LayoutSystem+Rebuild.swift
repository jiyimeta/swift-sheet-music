#if canImport(CoreGraphics)
    import CoreGraphics
#endif

/// The two copy-with-one-field rebuilds the layout pipeline performs on
/// an already-built `LayoutSystem`.
///
/// `LayoutSystem` is a `let`-only value type, so a pass that appends
/// spanners or moves a system down the page cannot mutate one field: it
/// has to re-invoke `init` and hand back every field. Two of those —
/// `staffAddresses` and `staffGeometries` — are defaulted, and their
/// default is not neutral. An omitted `staffGeometries` reads as "every
/// staff is standard five-line", so a rebuild that drops it compiles,
/// ships green, and silently reverts that system's staves to five-line
/// geometry: barline spans, ledger bounds, the skyline band and the
/// playback cursor all quietly change on a percussion staff, with
/// nothing failing anywhere. Six such sites had to be found and fixed by
/// hand while the line-count feature was being built.
///
/// These two shapes are the only ones the library needs, so routing
/// every rebuild through them makes that mistake unrepresentable rather
/// than merely detectable, and a future field is carried forward by
/// changing this file alone.
extension LayoutSystem {
    /// A copy of this system with `extra` appended to `spanners`.
    ///
    /// Used by the three passes that resolve cross-measure geometry
    /// after measure placement — `attachSpanners`, `attachTies`,
    /// `attachGlissandi`. Each computes its own segments per system and
    /// then needs a system that is identical apart from carrying them.
    public func addingSpanners(_ extra: [LayoutElement]) -> LayoutSystem {
        LayoutSystem(
            origin: origin,
            size: size,
            measures: measures,
            staffOrigins: staffOrigins,
            staffAddresses: staffAddresses,
            staffGeometries: staffGeometries,
            partLabels: partLabels,
            brackets: brackets,
            spanners: spanners + extra,
            sp: sp,
            invisibleSpanners: invisibleSpanners,
            showsInvisibleElements: showsInvisibleElements,
        )
    }

    /// A copy of this system moved `dy` further down the document.
    ///
    /// Only `origin.y` moves: every other coordinate a system carries is
    /// relative to that origin, which is what lets vertical packing
    /// (`LayoutEngine.shift`) and page slicing
    /// (`LayoutDocument.subdocument`) reposition a whole system this
    /// cheaply. A negative `dy` lifts it — that is how a page-mode
    /// renderer brings its first system to y ≈ 0.
    public func movedBy(dy: CGFloat) -> LayoutSystem {
        LayoutSystem(
            origin: CGPoint(x: origin.x, y: origin.y + dy),
            size: size,
            measures: measures,
            staffOrigins: staffOrigins,
            staffAddresses: staffAddresses,
            staffGeometries: staffGeometries,
            partLabels: partLabels,
            brackets: brackets,
            spanners: spanners,
            sp: sp,
            invisibleSpanners: invisibleSpanners,
            showsInvisibleElements: showsInvisibleElements,
        )
    }
}
