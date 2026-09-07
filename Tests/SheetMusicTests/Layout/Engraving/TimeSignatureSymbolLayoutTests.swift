#if canImport(CoreGraphics)
    import CoreGraphics
#endif
@testable import SheetMusicCore
@testable import SheetMusicLayout
import Testing

#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    /// A time signature drawn as a symbol reaches the renderers as one `LayoutElement.timeSignature` carrying
    /// that symbol — inline at the head of its bar, and again in the end-of-system courtesy that announces it.
    @Suite("Time signature symbols — layout")
    struct TimeSignatureSymbolLayoutTests {
        /// `LayoutEngine.layout` asserts a real FontMetrics provider.
        private let _installApple = TestSupport.installApple

        private static func chord() -> VoiceElement {
            .chord(Chord(duration: .whole, notes: ChordNotes([Note(pitch: 60, tpc: 14)])))
        }

        /// Four bars: m0 opens in 4/4, m2 changes to `change` and opens system 2 (m1 carries a line break), so
        /// m1's trailing edge is where the courtesy for that change lands.
        private static func score(change: TimeSignature) -> Score {
            let staff = Staff(measures: [
                Measure(voices: [Voice(elements: [
                    .clef(Clef(concertClefType: "G")),
                    .keySignature(KeySignature(concertKey: 0)),
                    .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                    chord(),
                ])]),
                Measure(voices: [Voice(elements: [chord()])], lineBreak: true),
                Measure(voices: [Voice(elements: [.timeSignature(change), chord()])]),
                Measure(voices: [Voice(elements: [chord()])]),
            ])
            return Score(
                division: 480,
                parts: [Part(id: "P0", instrument: Instrument(id: "voice0"), staves: [staff])],
            )
        }

        private func symbols(inMeasure index: Int, of score: Score) -> [TimeSignatureSymbol] {
            let document = LayoutEngine.layout(
                score: score, options: ScoreViewOptions(), availableWidth: 900,
            )
            return document.systems
                .flatMap(\.measures)
                .filter { $0.measureIndex == index }
                .flatMap(\.elements)
                .compactMap { element in
                    guard case let .timeSignature(_, _, symbol, _) = element else { return nil }
                    return symbol
                }
        }

        @Test("the symbol reaches the renderers on the inline signature")
        func inlineSignatureCarriesTheSymbol() {
            let change = TimeSignature(numerator: 2, denominator: 2, symbol: .cutCommon)
            #expect(symbols(inMeasure: 2, of: Self.score(change: change)) == [.cutCommon])
        }

        @Test("the opening signature's symbol reaches the renderers too")
        func openingSignatureCarriesTheSymbol() {
            var opening = Self.score(change: TimeSignature(numerator: 3, denominator: 4))
            opening.parts[0].staves[0].measures[0].voices[0].elements[2] =
                .timeSignature(TimeSignature(numerator: 4, denominator: 4, symbol: .common))
            #expect(symbols(inMeasure: 0, of: opening) == [.common])
        }

        /// The courtesy is the change restated at the previous system's trailing edge, so it must be restated
        /// in the same shape: a system ending before a cut-time bar announces the ¢, not "2/2".
        @Test("the courtesy announces the symbol, not the numbers it stands for")
        func courtesyCarriesTheSymbol() {
            let change = TimeSignature(numerator: 2, denominator: 2, symbol: .cutCommon)
            #expect(symbols(inMeasure: 1, of: Self.score(change: change)) == [.cutCommon])
        }

        @Test("a numeric change still announces as numbers")
        func numericCourtesyUnchanged() {
            let change = TimeSignature(numerator: 3, denominator: 4)
            #expect(symbols(inMeasure: 1, of: Self.score(change: change)) == [.numeric])
        }
    }
#endif
