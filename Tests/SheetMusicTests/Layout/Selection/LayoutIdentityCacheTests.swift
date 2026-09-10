import SheetMusicCore
@testable import SheetMusicLayout
import Testing

@Suite("Element identity through layout reuse")
struct LayoutIdentityCacheTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    @Test("Unchanged identity reuses systems; changing pitched eligibility invalidates placement")
    func pitchedEligibilityInvalidatesCache() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let measure = Measure(voices: [Voice(elements: [
            .keySignature(KeySignature(concertKey: 2)),
            .chord(Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)])),
        ])])
        // Pin the clef so changing group alone does not select percussion glyph geometry.
        var score = Score(division: 480, parts: [Part(
            id: "a", instrument: Instrument(id: "a"),
            staves: [Staff(defaultClefType: "G", measures: [measure, measure])],
        )])
        let cache = LayoutCache()
        let first = LayoutEngine.layout(score: score, options: .init(), availableWidth: 1000, cache: cache)
        let second = LayoutEngine.layout(score: score, options: .init(), availableWidth: 1000, cache: cache)
        #expect(cache.systemHits == second.systems.count)
        #expect(cache.systemMisses == 0)
        #expect(Self.keys(first) == Self.keys(second))
        #expect(Self.keys(second).compactMap(\.elementID) == [
            .keySignature(measureIndex: 0), .keySignature(measureIndex: 1),
        ])
        score.parts[0].staves[0].group = "percussion"
        let third = LayoutEngine.layout(score: score, options: .init(), availableWidth: 1000, cache: cache)
        #expect(cache.systemMisses == third.systems.count)
        #expect(cache.placementMisses == 2)
        #expect(Self.keys(third).count == 2)
        #expect(Self.keys(third).allSatisfy { $0.elementID == nil })
        let fourth = LayoutEngine.layout(score: score, options: .init(), availableWidth: 1000, cache: cache)
        #expect(cache.systemHits == fourth.systems.count)
        #expect(cache.systemMisses == 0)
        #expect(Self.keys(third) == Self.keys(fourth))
    }

    private static func keys(_ document: LayoutDocument) -> [LayoutElement] {
        document.systems.flatMap(\.measures).flatMap(\.elements).filter {
            if case .keySignature = $0 { true } else { false }
        }
    }

    @Test("Collapsed-run proxy barlines remain explicitly unaddressed")
    func collapsedProxyHasNoIdentity() {
        guard #available(macOS 15.0, iOS 16.0, *) else { return }
        let measure = Measure(voices: [Voice(elements: [.rest(duration: .measure)])])
        let score = Score(division: 480, parts: [Part(
            id: "a", instrument: Instrument(id: "a"),
            staves: [Staff(measures: [measure, measure, measure])],
        )])
        let document = LayoutEngine.layout(
            score: score, options: .init(multiMeasureRest: .collapse(minimumMeasures: 2)), availableWidth: 1000,
        )
        let collapsed = document.systems.flatMap(\.measures).filter { $0.multiMeasureRest != nil }
        #expect(collapsed.count == 1)
        let bars = collapsed.flatMap(\.elements).filter { if case .barLine = $0 { true } else { false } }
        #expect(bars.count == 1)
        #expect(bars.allSatisfy { $0.elementID == nil })
    }

    @Test("Identity participates in element and render-content equality even with unchanged geometry")
    func renderContentEqualityIncludesIdentity() {
        let bar = LayoutElement.barLine(
            subtype: nil, origin: .zero, halfHeight: 10, measureIndex: 1, role: .trailing,
        )
        let differentRole = LayoutElement.barLine(
            subtype: nil, origin: .zero, halfHeight: 10, measureIndex: 1, role: .explicit,
        )
        let differentMeasure = LayoutElement.barLine(
            subtype: nil, origin: .zero, halfHeight: 10, measureIndex: 2, role: .trailing,
        )
        #expect(bar != differentRole)
        #expect(bar != differentMeasure)
        let original = LayoutMeasure(measureIndex: 1, origin: .zero, width: 100, elements: [bar])
        let same = LayoutMeasure(measureIndex: 1, origin: .zero, width: 100, elements: [bar])
        let changed = LayoutMeasure(measureIndex: 1, origin: .zero, width: 100, elements: [differentRole])
        #expect(original.hasSameRenderContent(as: same))
        #expect(!original.hasSameRenderContent(as: changed))
    }
}
