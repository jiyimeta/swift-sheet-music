#if os(macOS)
    import CoreGraphics
    import SheetMusicLayout
    @testable import SheetMusicUI
    import Testing

    /// Unit coverage for `MeasureLayerDiffPlanner`, the pure decision
    /// logic behind `SystemLayerView`'s incremental measure update
    /// (Task 8). The golden-PNG rendering proof only exercises the
    /// full-rebuild path — there is no rasterized fixture for a diffed
    /// update — so this planner's own behavior is the only automated
    /// coverage for which measures rebuild, reposition, or get dropped.
    @Suite("MeasureLayerDiffPlanner")
    struct MeasureLayerDiffPlannerTests {
        /// A measure with distinguishable content (one `barLine` whose
        /// `subtype` encodes an identity token) so tests can flip a
        /// single measure's render content without touching the others.
        private func measure(
            index: Int, originX: CGFloat, contentToken: String = "a",
        ) -> LayoutMeasure {
            LayoutMeasure(
                measureIndex: index,
                origin: CGPoint(x: originX, y: 0),
                width: 100,
                elements: [.barLine(subtype: contentToken, origin: .zero)],
            )
        }

        private func system(
            measures: [LayoutMeasure],
            showsInvisibleElements: Bool = false,
        ) -> LayoutSystem {
            LayoutSystem(
                origin: .zero,
                size: CGSize(width: 300, height: 100),
                measures: measures,
                staffOrigins: [],
                partLabels: [],
                spanners: [],
                sp: 7,
                showsInvisibleElements: showsInvisibleElements,
            )
        }

        @Test("a content change in one measure rebuilds only that measure")
        func contentChangeRebuildsOnlyThatMeasure() {
            let previous = system(measures: [
                measure(index: 0, originX: 0),
                measure(index: 1, originX: 100),
                measure(index: 2, originX: 200),
            ])
            let next = system(measures: [
                measure(index: 0, originX: 0),
                measure(index: 1, originX: 100, contentToken: "b"),
                measure(index: 2, originX: 200),
            ])

            let plan = MeasureLayerDiffPlanner.plan(previous: previous, system: next)

            #expect(plan.updates[0] == .reposition(newOriginX: nil))
            #expect(plan.updates[1] == .rebuild)
            #expect(plan.updates[2] == .reposition(newOriginX: nil))
            #expect(plan.removed.isEmpty)
        }

        @Test("a pure origin.x shift repositions without rebuilding")
        func pureShiftReposition() {
            // Measure 1's content is identical; only its X moved (e.g.
            // because measure 0 grew wider upstream).
            let previous = system(measures: [
                measure(index: 0, originX: 0),
                measure(index: 1, originX: 100),
            ])
            let next = system(measures: [
                measure(index: 0, originX: 0),
                measure(index: 1, originX: 120),
            ])

            let plan = MeasureLayerDiffPlanner.plan(previous: previous, system: next)

            #expect(plan.updates[0] == .reposition(newOriginX: nil))
            #expect(plan.updates[1] == .reposition(newOriginX: 120))
            #expect(plan.removed.isEmpty)
        }

        @Test("a removed measure's container is dropped")
        func removedMeasureIsDropped() {
            let previous = system(measures: [
                measure(index: 0, originX: 0),
                measure(index: 1, originX: 100),
                measure(index: 2, originX: 200),
            ])
            let next = system(measures: [
                measure(index: 0, originX: 0),
                measure(index: 2, originX: 100),
            ])

            let plan = MeasureLayerDiffPlanner.plan(previous: previous, system: next)

            #expect(plan.removed == [1])
            #expect(plan.updates.count == 2)
            #expect(plan.updates[0] == .reposition(newOriginX: nil))
            // Measure 2 slid left to close the gap left by the removal.
            #expect(plan.updates[2] == .reposition(newOriginX: 100))
        }

        @Test("a brand-new measure index rebuilds (no previous render to diff against)")
        func newMeasureRebuilds() {
            let previous = system(measures: [
                measure(index: 0, originX: 0),
            ])
            let next = system(measures: [
                measure(index: 0, originX: 0),
                measure(index: 1, originX: 100),
            ])

            let plan = MeasureLayerDiffPlanner.plan(previous: previous, system: next)

            #expect(plan.updates[0] == .reposition(newOriginX: nil))
            #expect(plan.updates[1] == .rebuild)
            #expect(plan.removed.isEmpty)
        }

        @Test("systemFrameIsUnchanged ignores per-measure element content")
        func systemFrameIgnoresMeasureElements() {
            // Same furniture, different measure content — a measure-level
            // diff is still sufficient; this predicate must say true.
            let previous = system(measures: [measure(index: 0, originX: 0)])
            let next = system(measures: [
                measure(index: 0, originX: 0, contentToken: "different"),
            ])

            #expect(MeasureLayerDiffPlanner.systemFrameIsUnchanged(previous, next))
        }

        @Test("systemFrameIsUnchanged is false when a measure's invisibleElements change")
        func systemFrameCatchesInvisibleElementsChange() {
            // Invisible elements are drawn into ONE shared system-wide
            // layer, not a per-measure container, so a change here must
            // force the full rebuild path rather than the measure diff.
            let previous = system(measures: [
                LayoutMeasure(
                    measureIndex: 0, origin: .zero, width: 100, elements: [],
                    invisibleElements: [],
                ),
            ])
            let next = system(measures: [
                LayoutMeasure(
                    measureIndex: 0, origin: .zero, width: 100, elements: [],
                    invisibleElements: [.barLine(subtype: nil, origin: .zero)],
                ),
            ])

            #expect(!MeasureLayerDiffPlanner.systemFrameIsUnchanged(previous, next))
        }

        @Test("systemFrameIsUnchanged is false when a system-level field changes")
        func systemFrameCatchesSystemLevelChange() {
            let previous = system(measures: [measure(index: 0, originX: 0)])
            let next = system(
                measures: [measure(index: 0, originX: 0)],
                showsInvisibleElements: true,
            )

            #expect(!MeasureLayerDiffPlanner.systemFrameIsUnchanged(previous, next))
        }
    }
#endif
