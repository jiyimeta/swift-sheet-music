#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore
@testable import SheetMusicLayout
import Testing

@Suite("Lyric layout element identity")
struct LyricLayoutElementTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    @Test func lyricMarkCarriesItsVoiceElementAnchor() throws {
        let staffAddress = StaffAddress(
            partIndex: 0, staffIndexInPart: 0,
        )
        let expectedAnchor = VoiceElementID(
            staff: staffAddress,
            measureIndex: 0,
            voiceIndex: 0,
            elementIndex: 0,
        )
        let chord = Chord(
            duration: .whole,
            notes: ChordNotes([Note(pitch: 60, tpc: 14)]),
            lyrics: [
                Lyric(text: "", verse: 0),
                Lyric(text: "alto", verse: 1),
            ],
        )
        let score = Score(
            division: 480,
            parts: [Part(
                id: "P1",
                instrument: Instrument(id: "voice"),
                staves: [Staff(measures: [Measure(voices: [Voice(
                    elements: [.chord(chord)],
                )])])],
            )],
        )
        let document = LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(staffSize: 28),
            availableWidth: 800,
        )
        let mark = try #require(document.systems
            .flatMap(\.measures)
            .flatMap(\.elements)
            .first { element in
                if case .textMark(.lyrics, _, _) = element { return true }
                return false
            })
        guard case let .textMark(
            .lyrics(_, verse, anchor), _, _,
        ) = mark else {
            Issue.record("Expected a lyric text mark")
            return
        }

        #expect(verse == 1)
        #expect(anchor == expectedAnchor)
    }
}
