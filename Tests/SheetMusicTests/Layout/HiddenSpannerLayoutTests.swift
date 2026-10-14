import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if !canImport(CoreGraphics)
    /// On Android and WebAssembly, SheetMusicCore and SheetMusicLayout both export portable
    /// `CGFloat` / `CGPoint` shims, so anchor explicitly to SheetMusicLayout's definitions.
    private typealias CGFloat = SheetMusicLayout.CGFloat
    private typealias CGPoint = SheetMusicLayout.CGPoint
#endif

/// Layout draws a begin side that is visible, and nothing else: a hidden begin side and a payload-less end marker
/// both stay out of the system's spanners.
@Suite("Hidden spanner layout")
struct HiddenSpannerLayoutTests {
    @Test("only a visible begin side becomes an anchor")
    func onlyVisibleBeginSidesAreCollected() {
        let hiddenHairpin = Spanner(
            kind: .hairpin, rawType: "HairPin", nextMeasuresOffset: 1, visible: false,
            hairpin: .init(subtype: .crescendo), isEndMarker: false,
        )
        let endMarker = Spanner(kind: .pedal, rawType: "Pedal", isEndMarker: true)
        let pedal = Spanner(kind: .pedal, rawType: "Pedal", nextMeasuresOffset: 1)
        let chord = Chord(duration: .whole, notes: ChordNotes([Note(pitch: 72, tpc: 14)]))
        let score = Score(division: 480, parts: [Part(
            id: "P1", instrument: Instrument(id: "piano"),
            staves: [Staff(measures: [
                Measure(voices: [Voice(elements: [
                    .spanner(hiddenHairpin), .spanner(pedal), .chord(chord), .spanner(endMarker),
                ])]),
                Measure(voices: [Voice(elements: [.chord(chord)])]),
            ])],
        )])
        let kinds = LayoutEngine.collectSpanners(score: score).map(\.kind)
        #expect(kinds == [.pedal])
    }
}
