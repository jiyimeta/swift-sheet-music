import SheetMusicCore
import SheetMusicFoundation
@testable import SheetMusicLayout
import Testing

@Suite("Text placement")
struct TextPlacementTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    @Test func aboveLyricMovesToOtherSide() throws {
        func position(_ side: Placement) throws -> CGFloat {
            var lyric = Lyric(text: "Ag")
            lyric.elementProperties.placement = side
            let score = Score(division: 480, parts: [Part(
                id: "P1", instrument: Instrument(id: "voice"),
                staves: [Staff(measures: [Measure(voices: [Voice(elements: [
                    .chord(Chord(duration: .whole, notes: ChordNotes([Note(pitch: 60, tpc: 14)]), lyrics: [lyric])),
                ])])])],
            )])
            let document = LayoutEngine.layout(
                score: score,
                options: ScoreViewOptions(staffSize: 28),
                availableWidth: 800,
            )
            let system = try #require(document.systems.first)
            let mark = try #require(system.measures.flatMap(\.elements).first {
                if case .textMark(.lyrics, _, _) = $0 { return true }
                return false
            })
            guard case let .textMark(_, _, origin) = mark else { return 0 }
            let chord = try #require(system.measures.flatMap(\.elements).first {
                if case .chord = $0 { return true }
                return false
            })
            return origin.y - (LayoutEngine.elementYPoints(chord).first ?? 0)
        }
        #expect(try position(.above) < 0)
        #expect(try position(.below) > 0)
    }
}
