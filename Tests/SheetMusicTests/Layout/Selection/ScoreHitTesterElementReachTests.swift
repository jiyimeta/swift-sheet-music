#if os(macOS)
    import CoreGraphics
    import Foundation
    import SheetMusicCore
    @testable import SheetMusicLayout
    import SheetMusicMSCX
    import Testing

    /// `ScoreHitTester.hitElement(at:)` measures only the systems, measures and spanners that could reach the
    /// point. These pin that what it skips could never have answered: on real scores, in both layouts, it agrees
    /// point for point with a scan of every element in emission order — on every place an element is drawn, and on
    /// empty paper across the whole document.
    @Suite("Element hits skip only what cannot reach the point")
    struct ScoreHitTesterElementReachTests {
        private let _installFontMetrics = TestSupport.installFontMetrics

        private static let fixtures = [
            "testSingleNoteDynamics", "testVoltaTemp", "repeat52", "lyrics_verses_melisma", "slur_ms4_resave",
            "spanner_offsets_score_end", "guitarbend_simple", "testMeasureRepeats",
        ]

        private func documents(_ name: String) throws -> [LayoutDocument] {
            let url = URL(fileURLWithPath: "Tests/SheetMusicTests/Resources").appendingPathComponent("\(name).mscx")
            let score = try MSCXParser.parse(Data(contentsOf: url))
            let horizontal = ScoreViewOptions(wrapToViewWidth: false)
            return [
                LayoutEngine.layout(
                    score: score, options: horizontal,
                    availableWidth: LayoutEngine.naturalContentWidth(score: score, options: horizontal),
                ),
                LayoutEngine.layout(
                    score: score, options: ScoreViewOptions(wrapToViewWidth: true), availableWidth: 500,
                ),
            ]
        }

        /// Every element, every system, in emission order — what `hitElement(at:)` did before it pruned.
        @available(macOS 15.0, *)
        private func everyElement(_ tester: ScoreHitTester, at point: CGPoint) -> ScoreHitTarget? {
            for system in tester.document.systems {
                for measure in system.measures {
                    let base = CGPoint(x: system.origin.x + measure.origin.x, y: system.origin.y + measure.origin.y)
                    for elements in [measure.elements, measure.markers, measure.jumps, measure.invisibleElements] {
                        if let target = tester.hitElement(elements: elements, base: base, point: point) {
                            return target
                        }
                    }
                }
                for elements in [system.spanners, system.invisibleSpanners] {
                    if let target = tester.hitElement(elements: elements, base: system.origin, point: point) {
                        return target
                    }
                }
            }
            return nil
        }

        /// Where every addressable element is drawn: the middle and the four corners, just inside and just outside,
        /// of each rectangle it occupies.
        @available(macOS 15.0, *)
        private func probes(_ tester: ScoreHitTester) -> [CGPoint] {
            var ids: [ScoreElementID] = []
            for system in tester.document.systems {
                for measure in system.measures {
                    for element in measure.elements + measure.markers + measure.jumps + measure.invisibleElements {
                        if let id = element.elementID { ids.append(id) }
                    }
                }
                for element in system.spanners + system.invisibleSpanners {
                    if let id = element.elementID { ids.append(id) }
                }
            }
            let nudge = tester.document.metrics.sp * 0.5
            var points: [CGPoint] = []
            for id in ids {
                for rect in tester.elementHitRects(for: ScoreHitTarget(elementID: id)) {
                    points.append(CGPoint(x: rect.midX, y: rect.midY))
                    for d in [-nudge, nudge] {
                        points += [
                            CGPoint(x: rect.minX - d, y: rect.minY - d), CGPoint(x: rect.maxX + d, y: rect.minY - d),
                            CGPoint(x: rect.minX - d, y: rect.maxY + d), CGPoint(x: rect.maxX + d, y: rect.maxY + d),
                        ]
                    }
                }
            }
            return points
        }

        @Test("pruned and exhaustive element hits agree wherever an element is drawn", arguments: fixtures)
        func agreesOnElements(fixture: String) throws {
            guard #available(macOS 15.0, *) else { return }
            for document in try documents(fixture) {
                let tester = ScoreHitTester(document: document)
                let points = probes(tester)
                var hits = 0
                for point in points {
                    let expected = everyElement(tester, at: point)
                    if expected != nil { hits += 1 }
                    #expect(tester.hitElement(at: point) == expected, "\(fixture) at \(point)")
                }
                if !points.isEmpty {
                    #expect(hits > 0, "sanity: \(fixture)'s probes landed on something")
                }
            }
        }

        @Test("pruned and exhaustive element hits agree across the whole page", arguments: fixtures)
        func agreesEverywhere(fixture: String) throws {
            guard #available(macOS 15.0, *) else { return }
            for document in try documents(fixture) {
                let tester = ScoreHitTester(document: document)
                let step = document.metrics.sp * 4
                var y: CGFloat = -step * 4
                while y < document.size.height + step * 4 {
                    var x: CGFloat = -step * 4
                    while x < document.size.width + step * 4 {
                        let point = CGPoint(x: x, y: y)
                        let expected = everyElement(tester, at: point)
                        #expect(tester.hitElement(at: point) == expected, "\(fixture) at \(point)")
                        x += step
                    }
                    y += step
                }
            }
        }
    }
#endif
