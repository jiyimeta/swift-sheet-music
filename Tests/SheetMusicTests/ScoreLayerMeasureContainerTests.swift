#if os(macOS)
    import CoreGraphics
    import QuartzCore
    import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicMSCX
    @testable import SheetMusicUI
    import Testing

    @Suite("ScoreLayerMeasureContainer")
    struct ScoreLayerMeasureContainerTests {
        private let _installApple = TestSupport.installApple

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

        @Test("one container per measure, positioned at its origin.x")
        func containerPerMeasure() throws {
            guard #available(macOS 15.0, *) else { return }
            let (system, metrics) = try firstSystem()
            let built = ScoreLayerBuilder.buildSystemWithItems(
                system, metrics: metrics,
            )
            #expect(built.measureContainers.count == system.measures.count)
            for m in system.measures {
                let container = try #require(
                    built.measureContainers[m.measureIndex],
                )
                #expect(container.position.x == m.origin.x)
                #expect(container.anchorPoint == CGPoint(x: 0, y: 0))
                #expect(container.superlayer === built.root)
            }
        }

        @Test("every measure item also appears in the flat items map")
        func itemsAreMerged() throws {
            guard #available(macOS 15.0, *) else { return }
            let (system, metrics) = try firstSystem()
            let built = ScoreLayerBuilder.buildSystemWithItems(
                system, metrics: metrics,
            )
            for (_, perMeasure) in built.measureItems {
                for (id, layers) in perMeasure {
                    let merged = try #require(built.items[id])
                    for layer in layers {
                        #expect(merged.contains { $0 === layer })
                    }
                }
            }
        }
    }
#endif
