import SheetMusicCore
import SheetMusicFoundation
@testable import SheetMusicLayout
import Testing

@Suite("Text placement lyric rows")
struct TextPlacementLyricRowsTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    private func lyric(
        _ text: String,
        verse: Int,
        side: Placement,
        ticks: Int = 0,
        syllabic: Syllabic = .single,
        autoplace: Bool = false,
    ) -> Lyric {
        var value = Lyric(text: text, syllabic: syllabic, ticks: ticks, verse: verse)
        value.elementProperties = ElementProperties(placement: side, autoplace: autoplace)
        return value
    }

    private func chord(_ lyrics: [Lyric], duration: NoteDuration = .whole) -> VoiceElement {
        .chord(Chord(duration: duration, notes: ChordNotes([Note(pitch: 71, tpc: 19)]), lyrics: lyrics))
    }

    private func score(_ measures: [Measure]) -> Score {
        Score(
            division: 480,
            parts: [Part(id: "P1", instrument: Instrument(id: "voice"), staves: [Staff(measures: measures)])],
        )
    }

    @Test func aboveMaximumVerseIsSystemWideAndVerseOrderIsTopToBottom() throws {
        let document = TextPlacementFixtures.layout(score([
            Measure(voices: [Voice(elements: [chord([lyric("A", verse: 0, side: .above)])])]),
            Measure(voices: [Voice(elements: [chord([
                lyric("B", verse: 0, side: .above),
                lyric("below", verse: 1, side: .below),
                lyric("C", verse: 2, side: .above),
            ])])]),
        ]))
        #expect(document.systems.count == 1)
        let system = try #require(document.systems.first)
        let marks = system.measures.flatMap(\.elements).filter { $0.textPlacement?.row != nil }
        #expect(marks.count == 4)
        let top = marks.filter { $0.textPlacement?.row == LyricRow(side: .above, verse: 0) }
        let inner = try #require(marks.first { $0.textPlacement?.verse == 2 })
        #expect(top.count == 2)
        for mark in top {
            #expect(abs(TextPlacementFixtures.origin(inner).y - TextPlacementFixtures.origin(mark).y - 23.8) < 0.001)
        }
        let below = try #require(marks.first { $0.textPlacement?.side == .below })
        #expect(TextPlacementFixtures.origin(below).y > (system.staffOrigins.first?.y ?? 0) + 28)
    }

    @Test func multipleMelismaRowsContinueThroughSyllableFreeSystems() throws {
        var first = Measure(voices: [Voice(elements: [chord([
            lyric("A", verse: 0, side: .above, ticks: 4800),
            lyric("B", verse: 1, side: .below, ticks: 4800),
            lyric("C", verse: 2, side: .above, ticks: 4800),
        ])])])
        first.lineBreak = true
        var second = Measure(voices: [Voice(elements: [chord([])])])
        second.lineBreak = true
        let document = TextPlacementFixtures.layout(score([
            first,
            second,
            Measure(voices: [Voice(elements: [chord([])])]),
        ]))
        #expect(document.systems.count == 3)
        var rowYs: [LyricRow: CGFloat] = [:]
        for (index, system) in document.systems.enumerated() {
            let lines = system.measures.flatMap(\.elements)
                .filter { if case .lyricsMelisma = $0 { true } else { false } }
            #expect(lines.count == 3)
            for line in lines {
                let metadata = try #require(line.textPlacement)
                let row = try #require(metadata.row)
                #expect(!metadata.autoplace)
                let y = TextPlacementFixtures.origin(line).y - (system.staffOrigins.first?.y ?? 0)
                if index == 0 { rowYs[row] = y } else { #expect(abs(y - (rowYs[row] ?? .infinity)) < 0.001) }
            }
        }
        let outer = try #require(rowYs[LyricRow(side: .above, verse: 0)])
        let inner = try #require(rowYs[LyricRow(side: .above, verse: 2)])
        #expect(outer < inner)
    }

    @Test(arguments: [false, true])
    func hyphenRowsKeepTheirSideAcrossMeasureAndSystemBreaks(systemBreak: Bool) throws {
        var first = Measure(voices: [Voice(elements: [chord([
            lyric("A", verse: 0, side: .above, syllabic: .begin),
            lyric("B", verse: 1, side: .below, syllabic: .begin),
        ])])])
        first.lineBreak = systemBreak
        let second = Measure(voices: [Voice(elements: [chord([
            lyric("C", verse: 0, side: .above, syllabic: .end),
            lyric("D", verse: 1, side: .below, syllabic: .end),
        ])])])
        let document = TextPlacementFixtures.layout(score([first, second]))
        #expect(document.systems.count == (systemBreak ? 2 : 1))
        for system in document.systems {
            let elements = system.measures.flatMap(\.elements)
            let hyphens = elements.filter { if case .lyricHyphen = $0 { true } else { false } }
            #expect(!hyphens.isEmpty)
            #expect(Set(hyphens.compactMap { $0.textPlacement?.row }) == Set([
                LyricRow(side: .above, verse: 0),
                LyricRow(side: .below, verse: 1),
            ]))
            for hyphen in hyphens {
                let mark = try #require(elements
                    .first {
                        if case .textMark = $0 { $0.textPlacement?.row == hyphen.textPlacement?.row } else { false }
                    })
                #expect(abs(TextPlacementFixtures.origin(mark).y - TextPlacementFixtures.origin(hyphen).y) < 0.001)
            }
        }
    }

    @Test(arguments: [false, true])
    func oppositeSidesDoNotConnect(withinMeasure: Bool) {
        let a = chord([lyric("A", verse: 0, side: .above, syllabic: .begin)], duration: .half)
        let b = chord([lyric("B", verse: 0, side: .below, syllabic: .end)], duration: .half)
        let measures = withinMeasure ? [Measure(voices: [Voice(elements: [a, b])])] : [
            Measure(voices: [Voice(elements: [a])]),
            Measure(voices: [Voice(elements: [b])]),
        ]
        let document = TextPlacementFixtures.layout(score(measures))
        #expect(!document.systems.flatMap(\.measures).flatMap(\.elements)
            .contains { if case .lyricHyphen = $0 { true } else { false } })
    }

    @Test(arguments: [0, 1, 2])
    func hyphenRetainsSourceAutoplaceAcrossDestinationChange(span: Int) {
        let a = chord([lyric("A", verse: 0, side: .above, syllabic: .begin, autoplace: false)], duration: .half)
        let b = chord([lyric("B", verse: 0, side: .above, syllabic: .end, autoplace: true)], duration: .half)
        var first = Measure(voices: [Voice(elements: span == 0 ? [a, b] : [a])])
        first.lineBreak = span == 2
        let measures = span == 0 ? [first] : [first, Measure(voices: [Voice(elements: [b])])]
        let document = TextPlacementFixtures.layout(score(measures))
        let hyphens = document.systems.flatMap(\.measures).flatMap(\.elements).filter {
            if case .lyricHyphen = $0 { true } else { false }
        }
        #expect(!hyphens.isEmpty)
        #expect(hyphens.allSatisfy { $0.textPlacement?.autoplace == false })
        if span == 2 {
            #expect(document.systems.count == 2)
            #expect(document.systems.allSatisfy { system in
                system.measures.flatMap(\.elements).contains { if case .lyricHyphen = $0 { true } else { false } }
            })
        }
    }

    @Test func caretUsesRequestedMixedSideVerse() throws {
        let document = TextPlacementFixtures.layout(score([Measure(voices: [Voice(elements: [chord([
            lyric("A", verse: 0, side: .above), lyric("B", verse: 1, side: .below),
        ])])])]))
        let system = try #require(document.systems.first)
        let mark = try #require(system.measures.flatMap(\.elements).first { $0.textPlacement?.verse == 1 })
        let anchor = VoiceElementID(
            staff: TextPlacementFixtures.address,
            measureIndex: 0,
            voiceIndex: 0,
            elementIndex: 0,
        )
        #expect(document.lyricLineY(at: anchor, verse: 1) == system.origin.y + TextPlacementFixtures.origin(mark).y)
    }

    @Test(arguments: [false, true])
    func oppositeSideInterruptsReturningTrail(withinMeasure: Bool) {
        let syllables = [
            chord([lyric("A", verse: 0, side: .above, syllabic: .begin)], duration: .quarter),
            chord([lyric("B", verse: 0, side: .below, syllabic: .middle)], duration: .quarter),
            chord([lyric("C", verse: 0, side: .above, syllabic: .end)], duration: .quarter),
        ]
        let measures = withinMeasure ? [Measure(voices: [Voice(elements: syllables)])]
            : syllables.map { Measure(voices: [Voice(elements: [$0])]) }
        let document = TextPlacementFixtures.layout(score(measures))
        #expect(!document.systems.flatMap(\.measures).flatMap(\.elements)
            .contains { if case .lyricHyphen = $0 { true } else { false } })
    }
}
