import SheetMusicCore
import Testing

struct ChordSpannersModelTests {
    @Test func chordCarriesAnchoredSpanners() {
        var chord = Chord(duration: .quarter, notes: [])
        #expect(chord.spanners.isEmpty)
        chord.spanners.append(Spanner(
            kind: .slur, rawType: "Slur", nextMeasuresOffset: 1,
        ))
        #expect(chord.spanners.count == 1)
        #expect(chord.spanners[0].kind == .slur)
    }
}
