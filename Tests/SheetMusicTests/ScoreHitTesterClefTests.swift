#if os(macOS)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    @testable import SheetMusicMSCX
    @testable import SheetMusicUI
    import Testing

    @Suite("ScoreHitTester — clef")
    struct ScoreHitTesterClefTests {
        @available(macOS 15.0, *)
        private func loadDoc(width: CGFloat = 2000) throws
            -> (LayoutDocument, Score)
        {
            let url = try #require(Bundle.module.url(
                forResource: "multiPartMixedStaves",
                withExtension: "mscx"
            ))
            let score = try MSCXParser.parse(contentsOf: url)
            let doc = LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(
                    staffSize: 18, systemGap: 16,
                    wrapToViewWidth: false
                ),
                availableWidth: width
            )
            return (doc, score)
        }

        @Test("hit on leading clef returns .clef(.staffDefault(...))")
        func hitsLeadingClef() throws {
            guard #available(macOS 15.0, *) else { return }
            let (doc, _) = try loadDoc()
            let tester = ScoreHitTester(document: doc)
            let system = try #require(doc.systems.first)
            let measure = try #require(system.measures.first)
            let clefEl = try #require(measure.elements.first {
                if case .clef = $0 { return true }
                return false
            })
            guard case let .clef(_, origin, _) = clefEl else {
                Issue.record("expected first element to be a clef")
                return
            }
            let point = CGPoint(
                x: system.origin.x + measure.origin.x + origin.x,
                y: system.origin.y + measure.origin.y + origin.y
            )
            let target = tester.hitTest(at: point)
            guard case let .clef(anchor) = target else {
                Issue.record("expected .clef hit, got \(String(describing: target))")
                return
            }
            if case .staffDefault = anchor {
                // OK
            } else {
                Issue.record("expected .staffDefault anchor, got \(anchor)")
            }
        }

        @Test("itemID(at:) on leading clef returns .clef(...)")
        func itemIDForLeadingClef() throws {
            guard #available(macOS 15.0, *) else { return }
            let (doc, _) = try loadDoc()
            let tester = ScoreHitTester(document: doc)
            let system = try #require(doc.systems.first)
            let measure = try #require(system.measures.first)
            guard case let .clef(_, origin, _) = (
                measure.elements.first { if case .clef = $0 { return true }; return false }
            ) else {
                Issue.record("no clef element")
                return
            }
            let point = CGPoint(
                x: system.origin.x + measure.origin.x + origin.x,
                y: system.origin.y + measure.origin.y + origin.y
            )
            guard case .clef = tester.itemID(at: point) else {
                Issue.record("itemID did not return .clef")
                return
            }
        }
    }
#endif
