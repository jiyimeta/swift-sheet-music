#if DEBUG && os(macOS)
    import SheetMusic
    import SheetMusicLayoutApple
    import SheetMusicUI
    import SwiftUI

    @available(macOS 15.0, *)
    private struct TextPlacementPreview: View {
        private let score: Score

        init() {
            _ = SheetMusicLayoutApple.install
            func lyric(_ text: String, verse: Int, side: Placement, syllabic: Syllabic) -> Lyric {
                var value = Lyric(text: text, syllabic: syllabic, verse: verse)
                value.elementProperties.placement = side
                return value
            }
            var harmony = Harmony(name: "Am7")
            harmony.elementProperties.placement = .below
            harmony.properties.style = [.italic]
            var above = StaffText(text: "Above\nstaff text")
            above.elementProperties.placement = .above
            var below = StaffText(text: "Below\nsystem text", isSystemText: true)
            below.elementProperties.placement = .below
            var rehearsal = RehearsalMark(text: "B\nframe", frame: .circle)
            rehearsal.elementProperties.placement = .below
            let voice = Voice(elements: [
                .spanner(Spanner(kind: .pedal, rawType: "Pedal", nextFractionsOffset: Fraction(1, 1))),
                .harmony(harmony),
                .chord(Chord(duration: .half, notes: [Note(pitch: 60, tpc: 14)], lyrics: [
                    lyric("Up", verse: 0, side: .above, syllabic: .begin),
                    lyric("Down", verse: 1, side: .below, syllabic: .begin),
                    lyric("Inner", verse: 2, side: .above, syllabic: .begin),
                ])),
                .chord(Chord(duration: .half, notes: [Note(pitch: 67, tpc: 15)], lyrics: [
                    lyric("per", verse: 0, side: .above, syllabic: .end),
                    lyric("ward", verse: 1, side: .below, syllabic: .end),
                    lyric("row", verse: 2, side: .above, syllabic: .end),
                ])),
            ])
            score = Score(
                division: 480,
                parts: [Part(
                    id: "voice",
                    instrument: Instrument(id: "voice"),
                    staves: [Staff(measures: [Measure(voices: [voice])])],
                )],
                systemMeasures: [SystemMeasure(elements: [
                    PositionedSystemElement(position: .start, element: .staffText(above)),
                    PositionedSystemElement(position: .start, element: .staffText(below)),
                    PositionedSystemElement(position: .start, element: .rehearsalMark(rehearsal)),
                ])],
            )
        }

        var body: some View {
            let document = LayoutEngine.layout(score: score, options: .init(staffSize: 28), availableWidth: 760)
            ScoreView(document: document, score: score)
                .padding(20)
                .frame(width: 800, height: 620, alignment: .topLeading)
                .background(.white)
        }
    }

    #Preview("Text placement sides and rows") {
        TextPlacementPreview()
    }
#endif
