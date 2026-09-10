import SheetMusicCore
import SheetMusicFoundation
@testable import SheetMusicLayout
import Testing

@Suite("Invisible above lyric rows")
struct InvisibleAboveLyricTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    @Test(arguments: [2, 3], [false, true])
    func hiddenHighVerseStaysAboveStaff(verse: Int, autoplace: Bool) throws {
        let document = layout(hiddenVerses: [verse], showsInvisible: true, autoplace: autoplace)
        let system = try #require(document.systems.first)
        let mark = try #require(system.measures.flatMap(\.invisibleElements).first { $0.textPlacement != nil })
        #expect(mark.textPlacement?.verse == verse)
        #expect(mark.textPlacement?.side == .above)
        #expect(abs(baseline(mark, system: system) + 14) < 0.001)
    }

    @Test func shownHiddenRowsKeepVerseOrderAcrossMeasures() throws {
        let document = layout(hiddenVerses: [2, 3], showsInvisible: true)
        let system = try #require(document.systems.first)
        let marks = system.measures.flatMap(\.invisibleElements).filter { $0.textPlacement != nil }
        #expect(marks.count == 2)
        let outer = try #require(marks.first { $0.textPlacement?.verse == 2 })
        let inner = try #require(marks.first { $0.textPlacement?.verse == 3 })
        #expect(abs(baseline(inner, system: system) + 14) < 0.001)
        #expect(abs(baseline(outer, system: system) + 25.9) < 0.001)
    }

    @Test(arguments: [2, 3])
    func hiddenRowsDoNotChangeNormalVisibleLayout(verse: Int) {
        let baseline = layout(hiddenVerses: [], showsInvisible: false, visibleVerse: true)
        let hidden = layout(hiddenVerses: [verse], showsInvisible: false, visibleVerse: true)
        #expect(baseline.systems.flatMap(\.measures).flatMap(\.elements)
            == hidden.systems.flatMap(\.measures).flatMap(\.elements))
        #expect(baseline.size == hidden.size)
        #expect(hidden.systems.flatMap(\.measures).flatMap(\.invisibleElements).isEmpty)
    }

    @Test func shownHiddenVerseSharesMaximumWithVisibleRows() throws {
        let document = layout(hiddenVerses: [3], showsInvisible: true, visibleVerse: true)
        let system = try #require(document.systems.first)
        let visible = system.measures.flatMap(\.elements).filter { $0.textPlacement != nil }
        let hidden = try #require(system.measures.flatMap(\.invisibleElements).first { $0.textPlacement != nil })
        #expect(visible.count == 2)
        #expect(abs(baseline(hidden, system: system) + 14) < 0.001)
        for mark in visible {
            #expect(abs(baseline(mark, system: system) + 49.7) < 0.001)
            #expect(baseline(mark, system: system) < baseline(hidden, system: system))
        }
    }

    private func baseline(_ mark: LayoutElement, system: LayoutSystem) -> CGFloat {
        let font = TextInkGeometry.font(for: .lyricsOdd, metrics: TextPlacementFixtures.metrics)
        let centerOffset = (FontMetrics.provider.ascent(font: font) - FontMetrics.provider.descent(font: font)) / 2
        return TextPlacementFixtures.origin(mark).y - system.staffOrigins[0].y + centerOffset
    }

    private func layout(
        hiddenVerses: [Int], showsInvisible: Bool, visibleVerse: Bool = false, autoplace: Bool = false,
    ) -> LayoutDocument {
        let measures = (0 ..< 2).map { index in
            var lyrics = (0 ... 3).map { Lyric(text: "", verse: $0) }
            if visibleVerse { lyrics[0].text = "Visible" }
            for verse in hiddenVerses where verse % 2 == index {
                lyrics[verse].text = "Hidden"
                lyrics[verse].visible = false
            }
            for index in lyrics.indices {
                lyrics[index].elementProperties.placement = .above
                lyrics[index].elementProperties.autoplace = autoplace
            }
            return Measure(voices: [Voice(elements: [.chord(Chord(
                duration: .whole, notes: [Note(pitch: 71, tpc: 19)], lyrics: lyrics,
            ))])])
        }
        let score = Score(division: 480, parts: [Part(
            id: "P", instrument: Instrument(id: "voice"), staves: [Staff(measures: measures)],
        )])
        return LayoutEngine.layout(
            score: score, options: ScoreViewOptions(staffSize: 28, showsInvisibleElements: showsInvisible),
            availableWidth: 800,
        )
    }
}
