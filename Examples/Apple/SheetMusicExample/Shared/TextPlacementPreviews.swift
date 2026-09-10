#if DEBUG && os(macOS)
    import SheetMusic
    import SheetMusicLayoutApple
    import SheetMusicUI
    import SwiftUI

    @available(macOS 15.0, *)
    private struct TextPlacementPreview: View {
        private let score: Score
        private let showsInvisible: Bool

        init(rehearsalText: String = "B\nframe", showsInvisible: Bool = false) {
            self.showsInvisible = showsInvisible
            _ = SheetMusicLayoutApple.install
            func lyric(_ text: String, verse: Int, side: Placement, syllabic: Syllabic) -> Lyric {
                var value = Lyric(text: text, syllabic: syllabic, verse: verse)
                value.elementProperties.placement = side
                if showsInvisible, verse >= 2 { value.visible = false }
                return value
            }
            var harmony = Harmony(name: "Am7")
            harmony.elementProperties.placement = .below
            harmony.properties.style = [.italic]
            var above = StaffText(text: "Above\nstaff text")
            above.elementProperties.placement = .above
            var below = StaffText(text: "Below\nsystem text", isSystemText: true)
            below.elementProperties.placement = .below
            var rehearsal = RehearsalMark(text: rehearsalText, frame: .circle)
            rehearsal.elementProperties.placement = .below
            let voice = Voice(elements: [
                .spanner(Spanner(
                    kind: .pedal,
                    rawType: "Pedal",
                    nextFractionsOffset: Fraction(numerator: 1, denominator: 1),
                )),
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
                    lyric(showsInvisible ? "Ghost verse 3" : "", verse: 3, side: .above, syllabic: .single),
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
            let document = LayoutEngine.layout(
                score: score, options: .init(staffSize: 28, showsInvisibleElements: showsInvisible),
                availableWidth: 760,
            )
            ScoreView(document: document, score: score)
                .padding(20)
                .frame(width: 800, height: 620, alignment: .topLeading)
                .background(.white)
        }
    }

    #Preview("Text placement sides and rows") {
        TextPlacementPreview()
    }

    #Preview("Single-line rehearsal circle") {
        TextPlacementPreview(rehearsalText: "A")
    }

    #Preview("Hidden above lyric rows") {
        TextPlacementPreview(showsInvisible: true)
    }
#endif
