#if os(macOS)
    import CoreGraphics
    import QuartzCore
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicMSCX
    @testable import SheetMusicUI
    import Testing

    /// Integration coverage for `MeasureDiffHosting.applyMeasureDiff` —
    /// the CALayer-mutating half of Task 8's incremental measure update,
    /// as opposed to `MeasureLayerDiffPlanner`'s pure decision logic
    /// (covered separately in `MeasureLayerDiffPlannerTests`). Neither
    /// the golden layout digest nor the rendered-preview PNG diff
    /// exercises this path — both only call `ScoreLayerBuilder
    /// .buildSystem` once per fixture, never a diffed second `configure`
    /// — so this suite is the only automated guard for it.
    ///
    /// Exercises `applyMeasureDiff` directly (not through
    /// `SystemLayerView`'s private `NSView` / `UIView` host) via a
    /// minimal `MeasureDiffHosting` conformer, which the Task 8 fix
    /// round's protocol extraction (review finding 5) made possible.
    @MainActor
    @Suite("MeasureDiffHosting.applyMeasureDiff")
    struct MeasureDiffHostingTests {
        private let _installApple = TestSupport.installApple

        /// Minimal, non-view conformer to `MeasureDiffHosting` so
        /// `applyMeasureDiff` can run without a live `NSView` / `UIView`
        /// host.
        final class MockHost: MeasureDiffHosting {
            var baseLayer: CALayer?
            var itemLayers: [ScoreItemID: [CAShapeLayer]] = [:]
            var measureContainers: [Int: CALayer] = [:]
            var measureItems: [Int: [ScoreItemID: [CAShapeLayer]]] = [:]
        }

        private func firstSystem() throws -> (LayoutSystem, StaffMetrics) {
            let url = URL(
                fileURLWithPath:
                "Tests/SheetMusicTests/Resources/testMeasureRepeats.mscx",
            )
            let score = try MSCXParser.parse(Data(contentsOf: url))
            let opts = ScoreViewOptions(wrapToViewWidth: false)
            let doc = LayoutEngine.layout(
                score: score, options: opts,
                availableWidth: LayoutEngine.naturalContentWidth(
                    score: score, options: opts,
                ),
            )
            let system = try #require(doc.systems.first)
            return (system, doc.metrics)
        }

        /// Returns a copy of `system` with the measure at `index`
        /// content-mutated (an extra `barLine` appended) and every
        /// other field — including every other measure — untouched, so
        /// `MeasureLayerDiffPlanner` demands rebuilding exactly that one
        /// measure via the diff path (not a full system rebuild).
        private func mutatingMeasure(
            in system: LayoutSystem, at index: Int,
        ) throws -> LayoutSystem {
            let original = try #require(
                system.measures.first { $0.measureIndex == index },
            )
            var measures = system.measures
            let position = try #require(
                measures.firstIndex { $0.measureIndex == index },
            )
            measures[position] = LayoutMeasure(
                measureIndex: original.measureIndex,
                origin: original.origin,
                width: original.width,
                elements: original.elements
                    + [.barLine(subtype: "diffprobe", origin: .zero)],
                markers: original.markers,
                jumps: original.jumps,
                lineBreak: original.lineBreak,
                pageBreak: original.pageBreak,
                tickColumns: original.tickColumns,
                multiMeasureRest: original.multiMeasureRest,
                invisibleElements: original.invisibleElements,
                chordNorthByTick: original.chordNorthByTick,
                dynamicExtents: original.dynamicExtents,
            )
            return LayoutSystem(
                origin: system.origin,
                size: system.size,
                measures: measures,
                staffOrigins: system.staffOrigins,
                staffAddresses: system.staffAddresses,
                partLabels: system.partLabels,
                brackets: system.brackets,
                spanners: system.spanners,
                sp: system.sp,
                invisibleSpanners: system.invisibleSpanners,
                showsInvisibleElements: system.showsInvisibleElements,
            )
        }

        /// Selects note A in one measure, then diffs in a content-only
        /// change to a DIFFERENT measure (A's measure untouched), then
        /// deselects A. A must end up back at `inkColor`.
        ///
        /// Pins Task 8 review finding 1: an earlier version of
        /// `applyMeasureDiff` reset `lastSelection` to `.empty` whenever
        /// ANY measure rebuilt, which corrupted
        /// `ScoreLayerBuilder.applySelection`'s `toReset` computation
        /// for every OTHER, non-rebuilt measure — a note selected
        /// before the edit but not touched by it would never get reset,
        /// staying tinted forever. This test calls
        /// `ScoreLayerBuilder.applySelection` itself (as `configure`
        /// does) with the TRUE previous/new selection state, so it only
        /// passes if `applyMeasureDiff` leaves that state alone.
        @Test("deselecting a note in an untouched measure resets it, across a diff-only edit")
        func selectionSurvivesUntouchedMeasureAcrossDiff() throws {
            guard #available(macOS 15.0, *) else { return }
            let (system, metrics) = try firstSystem()
            let built = ScoreLayerBuilder.buildSystemWithItems(system, metrics: metrics)
            #expect(system.measures.count >= 2, "fixture needs >=2 measures for this test")

            // Pick one measure with a selectable item to leave untouched,
            // and a DIFFERENT measure to rebuild.
            let keepIndex = try #require(
                built.measureItems.first { !$0.value.isEmpty }?.key,
            )
            let rebuildIndex = try #require(
                system.measures.map(\.measureIndex).first { $0 != keepIndex },
            )
            let keepID = try #require(built.measureItems[keepIndex]?.keys.first)

            let mock = MockHost()
            mock.baseLayer = built.root
            mock.itemLayers = built.items
            mock.measureContainers = built.measureContainers
            mock.measureItems = built.measureItems

            let selectedColor = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
            let priorSelection = SelectionRenderState(
                selectedIDs: [keepID],
                voiceColors: [keepID.voiceIndex: selectedColor],
                drawRangeBox: false,
                rangeBoxColor: SelectionRenderState.defaultBoxColor,
            )
            // Simulate the PRIOR `configure()` call that selected A.
            ScoreLayerBuilder.applySelection(
                items: mock.itemLayers,
                previousSelection: .empty,
                newSelection: priorSelection,
            )
            let keepLayerBefore = try #require(mock.itemLayers[keepID]?.first)
            #expect(keepLayerBefore.fillColor == selectedColor, "sanity: tint applied")

            let modifiedSystem = try mutatingMeasure(in: system, at: rebuildIndex)
            #expect(
                MeasureLayerDiffPlanner.systemFrameIsUnchanged(system, modifiedSystem),
                "sanity: this edit must take the diff path, not the full rebuild",
            )

            mock.applyMeasureDiff(previous: system, system: modifiedSystem, metrics: metrics)

            // A's tint must still be intact right after the diff — the
            // diff alone must not have touched it.
            let keepLayerAfterDiff = try #require(mock.itemLayers[keepID]?.first)
            #expect(keepLayerAfterDiff.fillColor == selectedColor)

            // Now the user deselects A (selection clears). `configure`
            // would call this with `lastSelection` still holding the
            // TRUE prior state (`priorSelection`) — that's exactly what
            // finding 1 was about.
            ScoreLayerBuilder.applySelection(
                items: mock.itemLayers,
                previousSelection: priorSelection,
                newSelection: .empty,
            )
            let keepLayerFinal = try #require(mock.itemLayers[keepID]?.first)
            #expect(keepLayerFinal.fillColor == ScoreLayerBuilder.inkColor)
        }

        /// Pins Task 8 review finding 2: a rebuilt measure's container
        /// must land back at the same sublayer index its predecessor
        /// occupied in `root.sublayers`, not appended after every later
        /// measure (which would paint it on top of system spanners /
        /// the invisible-elements layer / later measures).
        @Test("a rebuilt measure's container keeps its z-order slot")
        func rebuildPreservesZOrder() throws {
            guard #available(macOS 15.0, *) else { return }
            let (system, metrics) = try firstSystem()
            let built = ScoreLayerBuilder.buildSystemWithItems(system, metrics: metrics)
            let indices = system.measures.map(\.measureIndex)
            // Rebuild a measure that is NOT the last, so an
            // append-to-the-end regression is actually observable
            // relative to later measure containers.
            let rebuildIndex = try #require(indices.dropLast().first)

            let mock = MockHost()
            mock.baseLayer = built.root
            mock.itemLayers = built.items
            mock.measureContainers = built.measureContainers
            mock.measureItems = built.measureItems

            let root = try #require(mock.baseLayer)
            let originalContainer = try #require(mock.measureContainers[rebuildIndex])
            let originalPosition = try #require(
                root.sublayers?.firstIndex { $0 === originalContainer },
            )

            let modifiedSystem = try mutatingMeasure(in: system, at: rebuildIndex)
            mock.applyMeasureDiff(previous: system, system: modifiedSystem, metrics: metrics)

            let newContainer = try #require(mock.measureContainers[rebuildIndex])
            #expect(newContainer !== originalContainer, "sanity: it was actually rebuilt")
            let newPosition = try #require(
                root.sublayers?.firstIndex { $0 === newContainer },
            )
            #expect(newPosition == originalPosition)
        }
    }
#endif
