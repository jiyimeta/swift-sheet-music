#if os(macOS)
    import CoreGraphics
    import Foundation
    import QuartzCore
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicMSCX
    @testable import SheetMusicUI
    import Testing

    /// Mounting part of one system: `ScoreLayerBuilder.buildSystemWithItems(visibleXRange:)`, `remount`, and
    /// `applyMeasureDiff` under a range. The invariant every test comes back to is that whatever path the host took
    /// to a range, its tree — what is mounted, in what z-order, with which selectable layers — is the one a fresh
    /// build for that range would have made.
    @MainActor
    @Suite("System mount by horizontal range")
    struct SystemMountTests {
        private let _installApple = TestSupport.installApple

        final class MockHost: MeasureDiffHosting {
            var baseLayer: CALayer?
            var itemLayers: [ScoreItemID: [CAShapeLayer]] = [:]
            var measureContainers: [Int: CALayer] = [:]
            var measureItems: [Int: [ScoreItemID: [CAShapeLayer]]] = [:]
            var mountedRange: ClosedRange<CGFloat>?
            var spannerLayers: [Int: MountedLayers] = [:]
            var invisibleLayers: MountedLayers?
            var invisibleMembership = InvisibleMembership()
        }

        /// The 38-measure, 17-hairpin fixture laid out horizontally: one long system with system-level spanners.
        private func horizontalSystem() throws -> (LayoutSystem, StaffMetrics) {
            let url = URL(fileURLWithPath: "Tests/SheetMusicTests/Resources/testSingleNoteDynamics.mscx")
            let score = try MSCXParser.parse(Data(contentsOf: url))
            let opts = ScoreViewOptions(wrapToViewWidth: false)
            let doc = LayoutEngine.layout(
                score: score, options: opts,
                availableWidth: LayoutEngine.naturalContentWidth(score: score, options: opts),
            )
            let system = try #require(doc.systems.first)
            try #require(system.measures.count >= 30)
            try #require(system.spanners.count >= 10)
            return (system, doc.metrics)
        }

        /// The X range from the start of the measure at `first` to the end of the one at `last` (positions in
        /// `system.measures`), pulled in by a point at each end so the neighbours it touches stay out.
        private func range(_ system: LayoutSystem, _ first: Int, _ last: Int) -> ClosedRange<CGFloat> {
            let a = system.measures[first]
            let b = system.measures[last]
            return (a.origin.x + 1) ... (b.origin.x + b.width - 1)
        }

        @available(macOS 15.0, *)
        private func host(_ system: LayoutSystem, _ metrics: StaffMetrics, _ range: ClosedRange<CGFloat>?) -> MockHost {
            let built = ScoreLayerBuilder.buildSystemWithItems(system, metrics: metrics, visibleXRange: range)
            let mock = MockHost()
            mock.baseLayer = built.root
            mock.adopt(built, range: range)
            return mock
        }

        /// The root's children, named by what they are: `m<index>` a measure container, `s<index>` a spanner's layer,
        /// `i` the hidden-element group, `f` the staves, brackets and labels.
        private func labels(_ mock: MockHost) -> [String] {
            (mock.baseLayer?.sublayers ?? []).map { layer in
                if let index = mock.measureContainers.first(where: { $0.value === layer })?.key {
                    return "m\(index)"
                }
                if let index = mock.spannerLayers.first(where: { $0.value.layers.contains { $0 === layer } })?.key {
                    return "s\(index)"
                }
                if mock.invisibleLayers?.layers.contains(where: { $0 === layer }) == true {
                    return "i"
                }
                return "f"
            }
        }

        private func itemCounts(_ mock: MockHost) -> [ScoreItemID: Int] {
            mock.itemLayers.mapValues(\.count)
        }

        /// A copy of `system` whose measures at `positions` also carry a hidden barline.
        private func hidingBarlines(in system: LayoutSystem, at positions: [Int]) -> LayoutSystem {
            var measures = system.measures
            for position in positions {
                let m = measures[position]
                measures[position] = LayoutMeasure(
                    measureIndex: m.measureIndex, origin: m.origin, width: m.width, elements: m.elements,
                    markers: m.markers, jumps: m.jumps, lineBreak: m.lineBreak, pageBreak: m.pageBreak,
                    tickColumns: m.tickColumns, multiMeasureRest: m.multiMeasureRest,
                    invisibleElements: [.barLine(
                        subtype: "hidden", origin: CGPoint(x: m.width / 2, y: 0), halfHeight: 4,
                        measureIndex: nil, role: .explicit,
                    )],
                    chordNorthByTick: m.chordNorthByTick, dynamicExtents: m.dynamicExtents,
                )
            }
            return LayoutSystem(
                origin: system.origin, size: system.size, measures: measures,
                staffOrigins: system.staffOrigins, staffAddresses: system.staffAddresses,
                staffGeometries: system.staffGeometries, partLabels: system.partLabels,
                brackets: system.brackets, spanners: system.spanners, sp: system.sp,
                invisibleSpanners: system.invisibleSpanners, showsInvisibleElements: true,
            )
        }

        @Test("a range builds the measures and spanners that meet it, and nothing else")
        func rangeBuildsWhatMeetsIt() throws {
            guard #available(macOS 15.0, *) else { return }
            let (system, metrics) = try horizontalSystem()
            let window = range(system, 10, 14)
            let mock = host(system, metrics, window)

            #expect(Set(mock.measureContainers.keys) == Set(system.measures[10 ... 14].map(\.measureIndex)))
            let expectedSpanners = system.spanners.indices.filter {
                SystemMount.meets(spanner: system.spanners[$0], window)
            }
            #expect(Set(mock.spannerLayers.keys) == Set(expectedSpanners))
            #expect(expectedSpanners.count < system.spanners.count, "sanity: the window leaves spanners out")

            let full = host(system, metrics, nil)
            #expect(full.measureContainers.count == system.measures.count)
            #expect(full.spannerLayers.count == system.spanners.count)
        }

        @Test("built for no range, the tree is furniture, then every measure, then every spanner, in order")
        func fullBuildKeepsItsOrder() throws {
            guard #available(macOS 15.0, *) else { return }
            let (system, metrics) = try horizontalSystem()
            let built = labels(host(system, metrics, nil)).filter { $0 != "f" }
            let expected = system.measures.map { "m\($0.measureIndex)" }
                + system.spanners.indices.flatMap { index in
                    let drawn = ScoreLayerBuilder.buildSpanner(system.spanners[index], of: system, metrics: metrics)
                    return Array(repeating: "s\(index)", count: drawn.layers.count)
                }
            #expect(built == expected)
        }

        @Test("remounting to a new range leaves the tree a fresh build for that range would make")
        func remountMatchesAFreshBuild() throws {
            guard #available(macOS 15.0, *) else { return }
            let (system, metrics) = try horizontalSystem()
            let mock = host(system, metrics, range(system, 4, 12))
            // Overlapping, then disjoint, then everything, then back: each step mounts and unmounts.
            for next in [range(system, 9, 20), range(system, 25, 30), nil, range(system, 0, 3)] {
                mock.remount(system: system, metrics: metrics, to: next)
                let fresh = host(system, metrics, next)
                #expect(labels(mock) == labels(fresh))
                #expect(itemCounts(mock) == itemCounts(fresh))
                #expect(mock.mountedRange == next)
            }
        }

        @Test("a selected note that mounts later comes in tinted")
        func selectionReachesLateMounts() throws {
            guard #available(macOS 15.0, *) else { return }
            let (system, metrics) = try horizontalSystem()
            let late = system.measures[20]
            let noteID = try #require(late.elements.compactMap { element -> ScoreItemID? in
                guard case let .chord(notes, _, _, _, _, _, _, _, _, _, _) = element else { return nil }
                return notes.first.map { .note($0.noteID) }
            }.first)
            let mock = host(system, metrics, range(system, 0, 5))
            #expect(mock.itemLayers[noteID] == nil, "sanity: not mounted yet")

            let red = CGColor(red: 1, green: 0, blue: 0, alpha: 1)
            let selection = SelectionRenderState(
                selectedIDs: [noteID], voiceColors: [noteID.voiceIndex: red],
                drawRangeBox: false, rangeBoxColor: SelectionRenderState.defaultBoxColor,
            )
            ScoreLayerBuilder.applySelection(items: mock.itemLayers, previousSelection: .empty, newSelection: selection)

            // What `configure` does when only the window moved: remount, then re-apply the unchanged selection.
            mock.remount(system: system, metrics: metrics, to: range(system, 18, 22))
            ScoreLayerBuilder.applySelection(
                items: mock.itemLayers, previousSelection: selection, newSelection: selection,
            )
            let layer = try #require(mock.itemLayers[noteID]?.first)
            #expect(layer.fillColor == red)
        }

        @Test("the hidden-element group holds what is mounted, and follows the range")
        func invisibleGroupFollowsTheRange() throws {
            guard #available(macOS 15.0, *) else { return }
            let (plain, metrics) = try horizontalSystem()
            let system = hidingBarlines(in: plain, at: [2, 20])
            let mock = host(system, metrics, range(system, 0, 5))
            #expect(mock.invisibleMembership.measures == [system.measures[2].measureIndex])
            #expect(labels(mock).last == "i")

            mock.remount(system: system, metrics: metrics, to: range(system, 18, 22))
            #expect(mock.invisibleMembership.measures == [system.measures[20].measureIndex])
            #expect(labels(mock) == labels(host(system, metrics, range(system, 18, 22))))

            mock.remount(system: system, metrics: metrics, to: range(system, 8, 12))
            #expect(mock.invisibleLayers == nil)
            #expect(!labels(mock).contains("i"))
        }

        @Test("an edit diffed under a range mounts only what the range meets")
        func diffRespectsTheRange() throws {
            guard #available(macOS 15.0, *) else { return }
            let (system, metrics) = try horizontalSystem()
            let window = range(system, 10, 14)
            let mock = host(system, metrics, window)
            // Every measure but the last slides right by a quarter of the window: some leave it, some enter it. The
            // last stays put because the staff lines end where it does, and moving that is a full rebuild.
            let dx = (window.upperBound - window.lowerBound) / 4
            let last = system.measures.count - 1
            let measures = system.measures.enumerated().map { position, m in
                position == last ? m : LayoutMeasure(
                    measureIndex: m.measureIndex, origin: CGPoint(x: m.origin.x + dx, y: m.origin.y),
                    width: m.width, elements: m.elements, markers: m.markers, jumps: m.jumps,
                    lineBreak: m.lineBreak, pageBreak: m.pageBreak, tickColumns: m.tickColumns,
                    multiMeasureRest: m.multiMeasureRest, invisibleElements: m.invisibleElements,
                    chordNorthByTick: m.chordNorthByTick, dynamicExtents: m.dynamicExtents,
                )
            }
            let shifted = LayoutSystem(
                origin: system.origin, size: system.size, measures: measures,
                staffOrigins: system.staffOrigins, staffAddresses: system.staffAddresses,
                staffGeometries: system.staffGeometries, partLabels: system.partLabels,
                brackets: system.brackets, spanners: system.spanners, sp: system.sp,
                invisibleSpanners: system.invisibleSpanners, showsInvisibleElements: system.showsInvisibleElements,
            )
            try #require(MeasureLayerDiffPlanner.systemFrameIsUnchanged(system, shifted))

            mock.applyMeasureDiff(previous: system, system: shifted, metrics: metrics)
            // The diff itself must stay inside the window: building every measure only for `remount` to tear most
            // of them down again would cost what mounting by range is there to save.
            let inWindow = shifted.measures.filter { SystemMount.meets($0, window) }.map(\.measureIndex)
            #expect(Set(mock.measureContainers.keys) == Set(inWindow))
            mock.remount(system: shifted, metrics: metrics, to: window)

            let fresh = host(shifted, metrics, window)
            #expect(Set(mock.measureContainers.keys) == Set(fresh.measureContainers.keys))
            #expect(labels(mock) == labels(fresh))
            #expect(itemCounts(mock) == itemCounts(fresh))
            for m in shifted.measures {
                if let container = mock.measureContainers[m.measureIndex] {
                    #expect(container.position.x == m.origin.x)
                }
            }
        }

        @Test("ScoreView hands a system the part of the rect that does not span it")
        func scoreViewPassesOnlyAPartialRange() throws {
            guard #available(macOS 15.0, *) else { return }
            let (system, _) = try horizontalSystem()
            #expect(ScoreView.visibleXRange(of: system, in: nil) == nil)
            let whole = CGRect(x: system.origin.x - 5, y: 0, width: system.size.width + 10, height: 10)
            #expect(ScoreView.visibleXRange(of: system, in: whole) == nil)
            let part = CGRect(x: system.origin.x + 100, y: 0, width: 300, height: 10)
            #expect(ScoreView.visibleXRange(of: system, in: part) == 100 ... 400)
        }
    }
#endif
