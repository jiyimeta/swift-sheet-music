#if os(macOS)
    import CoreGraphics
    import Foundation
    import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    /// Presence check for the SwiftUI Canvas renderer's time-signature symbols.
    ///
    /// `ScoreCanvasDrawing.drawSystem` — the renderer behind PDF export and `PagedScoreView` — is a THIRD
    /// implementation of the same drawing, beside `ScoreLayerBuilder` (which the preview and corpus pixel
    /// gates rasterize) and `LayoutBridge` (which `LayoutBridgeTimeSignatureTests` reads command by command).
    /// Nothing else in the repo looks at this one, and the failure it would hide is silent: a `.numeric`
    /// fallthrough draws a perfectly plausible "4/4" where the score says C.
    ///
    /// A PRESENCE test, like `CanvasGraceChordInkTests`: no golden file, and a renderer that draws the wrong
    /// thing — or nothing — fails immediately.
    @Suite("Canvas time-signature symbol ink")
    struct CanvasTimeSignatureSymbolInkTests {
        private let _installApple = TestSupport.installApple

        /// One 4/4 bar of four B4 quarters, its signature drawn as `symbol`. The meter is 4/4 throughout, so
        /// the bars, the notes and the staff lines are identical in every variant and the ONLY thing that can
        /// move the ink is the signature glyph.
        private static func score(symbol: TimeSignatureSymbol) -> Score {
            let chord = Chord(
                duration: .quarter,
                // B4 — the middle line, clear of any ledger.
                notes: ChordNotes([Note(pitch: 71, tpc: 19)]),
            )
            let staff = Staff(measures: [Measure(voices: [Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4, symbol: symbol)),
                .chord(chord), .chord(chord), .chord(chord), .chord(chord),
            ])])])
            return Score(
                division: 480,
                parts: [Part(id: "P0", instrument: Instrument(id: "voice0"), staves: [staff])],
            )
        }

        @MainActor
        @Test("Canvas draws a different signature for every symbol")
        func everySymbolPutsItsOwnInkOnThePage() throws {
            guard #available(macOS 15.0, *) else { return }
            var inkBySymbol: [TimeSignatureSymbol: Int] = [:]
            for symbol in TimeSignatureSymbol.allCases {
                inkBySymbol[symbol] = try CanvasInkProbe.ink(of: Self.score(symbol: symbol))
            }
            let numeric = try #require(inkBySymbol[.numeric])
            #expect(numeric > 0, "the numeric signature should render some ink")
            // Every symbol is one glyph where `.numeric` is two digits, so none of them can coincide with it.
            // Equality here is what a `.numeric` fallthrough would produce, and it is the whole point of the
            // test: a delta of exactly zero means the symbol never reached the renderer.
            for symbol in TimeSignatureSymbol.allCases where symbol != .numeric {
                let ink = try #require(inkBySymbol[symbol])
                #expect(
                    ink != numeric,
                    """
                    Canvas drew \(symbol) exactly as it drew the numbers \
                    (\(ink) dark pixels either way), which is what a missing case looks like.
                    """,
                )
            }
        }
    }
#endif
