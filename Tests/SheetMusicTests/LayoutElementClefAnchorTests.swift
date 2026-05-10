import CoreGraphics
import Foundation
@testable import SheetMusicCore
@testable import SheetMusicLayout
@testable import SheetMusicMSCX
import Testing

@Suite struct LayoutElementClefAnchorTests {
    @available(macOS 15.0, iOS 16.0, *)
    @Test func staffDefaultAnchor() throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "multiPartMixedStaves",
                withExtension: "mscx"
            )
        )
        let score = try MSCXParser.parse(contentsOf: url)
        let doc = LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(
                staffSize: 18, systemGap: 16, wrapToViewWidth: false
            ),
            availableWidth: 2000
        )
        let firstMeasure = try #require(
            doc.systems.first?.measures.first
        )
        let anchors = firstMeasure.elements.compactMap { el -> ClefAnchor? in
            guard case let .clef(_, _, anchor) = el else { return nil }
            return anchor
        }
        #expect(anchors.contains { anchor in
            if case .staffDefault = anchor { return true }
            return false
        })
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test("sticky-header clef has nil anchor")
    func stickyHeaderHasNilAnchor() throws {
        let url = try #require(
            Bundle.module.url(
                forResource: "multiPartMixedStaves",
                withExtension: "mscx"
            )
        )
        let score = try MSCXParser.parse(contentsOf: url)
        let doc = LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(
                staffSize: 18, systemGap: 16,
                wrapToViewWidth: false
            ),
            availableWidth: 2000
        )
        let contexts = LayoutEngine.measureContexts(for: score)
        let firstContext = try #require(contexts.first)
        let templateSystem = try #require(doc.systems.first)
        let sticky = LayoutEngine.stickyHeaderSystem(
            for: firstContext,
            templateSystem: templateSystem,
            metrics: doc.metrics
        )
        let stickyMeasure = try #require(sticky.measures.first)
        // Sticky-header builds at least one clef per staff; every
        // one of them is a re-statement and must NOT be selectable.
        let hasClef = stickyMeasure.elements.contains { el in
            if case .clef = el { return true }
            return false
        }
        #expect(
            hasClef,
            "fixture should produce at least one clef in the sticky header"
        )
        for el in stickyMeasure.elements {
            if case let .clef(_, _, anchor) = el {
                #expect(anchor == nil)
            }
        }
    }

    @available(macOS 15.0, iOS 16.0, *)
    @Test("continuation-system synthesized clef has nil anchor")
    func continuationSystemSynthClefHasNilAnchor() throws {
        // `harmony-basic` reliably wraps into ≥3 systems at small
        // widths; `multiPartMixedStaves` (used by the other tests
        // here) is short enough that it always fits in one system,
        // so it can't exercise the continuation-system path.
        let url = try #require(
            Bundle.module.url(
                forResource: "harmony-basic",
                withExtension: "mscx"
            )
        )
        let score = try MSCXParser.parse(contentsOf: url)
        // Force a wrap by giving a tight width.
        let doc = LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(
                staffSize: 18, systemGap: 16,
                wrapToViewWidth: true
            ),
            availableWidth: 200
        )
        guard doc.systems.count >= 2 else {
            Issue.record(
                """
                expected the fixture to wrap into ≥2 systems at \
                availableWidth: 200; chose a different fixture / width if not
                """
            )
            return
        }
        for system in doc.systems.dropFirst() {
            let firstMeasure = try #require(system.measures.first)
            for el in firstMeasure.elements {
                if case let .clef(_, _, anchor) = el {
                    #expect(
                        anchor == nil,
                        "continuation-system clefs must not be selectable"
                    )
                }
            }
        }
    }
}
