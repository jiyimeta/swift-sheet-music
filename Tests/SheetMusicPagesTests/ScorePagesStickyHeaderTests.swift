import Foundation
@testable import SheetMusicBridgeCore
import SheetMusicCore
import SheetMusicLayout
@testable import SheetMusicPages
import Testing

/// `ScorePages.stickyHeader(scrollXPt:)`: the horizontal strip's sticky pane as a one-page `ScorePages` — the draw
/// program the Android bridge already gets (`LayoutBridge.stickyHeaderPage`), on a page the size of the synthesized
/// system, for a Windows host's second surface.
@Suite("ScorePages: the sticky header")
struct ScorePagesStickyHeaderTests {
    private static func provider() throws -> any FontMetricsProvider {
        let table = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/SheetMusicPagesTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root
            .appendingPathComponent("Web/sheet-music-web/assets/sheet-music.smft")
        return try makeFontMetricsTableProvider(table: FontMetricsTable.decode(Data(contentsOf: table)))
    }

    /// Two parts, eight bars, laid out as one horizontal strip.
    private static func strip() -> ScorePages {
        func staff() -> Staff {
            Staff(measures: (0 ..< 8).map { _ in
                Measure(voices: [Voice(elements: [
                    .chord(Chord(duration: .whole, notes: [Note(pitch: 60, tpc: 14)])),
                ])])
            })
        }
        let score = Score(division: 480, parts: [
            // Short names too: the pane labels the staves as a continuation system does.
            Part(id: "P1", instrument: Instrument(id: "flute", longName: "Flute", shortName: "Fl."), staves: [staff()]),
            Part(id: "P2", instrument: Instrument(id: "cello", longName: "Cello", shortName: "Vc."), staves: [staff()]),
        ])
        return ScorePages.compute(
            score: score, pageWidthMM: 200, pageHeightMM: 280, options: ScorePageOptions(mode: .horizontal),
        )
    }

    /// The middle of the strip's `index`-th measure, in document points.
    private static func middle(of index: Int, in pages: ScorePages) throws -> Double {
        let system = try #require(pages.document.systems.first)
        let measure = system.measures[index]
        return Double(system.origin.x + measure.origin.x + measure.width / 2)
    }

    @available(macOS 15.0, iOS 16.0, *) // `LayoutBridge.stickyHeaderPage`'s own availability
    @Test("the pane is the bridge's sticky page, on one page its own size")
    func matchesTheBridge() throws {
        try FontMetrics.$scopedProvider.withValue(Self.provider()) {
            let pages = Self.strip()
            let measures = try #require(pages.document.systems.first?.measures)
            try #require(measures.count == 8)
            for index in [0, 5] {
                let x = try Self.middle(of: index, in: pages)
                let header = try #require(pages.stickyHeader(scrollXPt: x))
                let direct = try #require(LayoutBridge.stickyHeaderPage(
                    score: pages.filteredScore, document: pages.document, scrollXPt: x,
                ))
                #expect(header.pageCount == 1)
                #expect(header.pages == [direct])
                #expect(header.document.systems.count == 1)
                let size = header.pageSizeMM(0)
                #expect(abs(size.width - Double(header.document.size.width) * 25.4 / 72) < 1e-9)
                #expect(abs(size.height - Double(header.document.size.height) * 25.4 / 72) < 1e-9)
                // The pane carries both parts' labels, and is narrower than the strip it freezes.
                let names = header.document.systems[0].measures.flatMap(\.elements).filter { element in
                    if case .staffName = element { true } else { false }
                }
                #expect(names.count == 2)
                #expect(header.document.size.width < pages.document.size.width)
            }
        }
    }

    @Test("a scroll past either end gives the first or the last measure's pane")
    func clampsAtTheEnds() throws {
        try FontMetrics.$scopedProvider.withValue(Self.provider()) {
            let pages = Self.strip()
            let before = try #require(pages.stickyHeader(scrollXPt: -1000))
            let first = try #require(pages.stickyHeader(scrollXPt: Self.middle(of: 0, in: pages)))
            let past = try #require(pages.stickyHeader(scrollXPt: Double(pages.document.size.width) + 1000))
            let last = try #require(pages.stickyHeader(scrollXPt: Self.middle(of: 7, in: pages)))
            #expect(before.pages == first.pages)
            #expect(past.pages == last.pages)
        }
    }
}
