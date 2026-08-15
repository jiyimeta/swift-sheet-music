#if os(macOS)
    import CoreGraphics
    import Foundation
    import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    /// Presence check for the SwiftUI Canvas renderer's grace chords.
    ///
    /// `ScoreCanvasDrawing.drawSystem` is the renderer behind PDF export
    /// (`PDFPageView`) and `PagedScoreView`, and it silently dropped
    /// `.graceChord` for the whole life of the file — the case was folded
    /// into `case .note, .graceChord: break`. Nothing in the repo could
    /// catch that: the corpus pixel gate rasterizes the CALayer tree only,
    /// and the Canvas path had no ink-level coverage at all.
    ///
    /// This is a PRESENCE test, not a pixel-exact one: it exports the same
    /// score twice, once with an acciaccatura on every chord and once
    /// without, and asserts the grace version puts substantially more ink
    /// on the page. No golden file, so no maintenance burden — but a
    /// renderer that draws nothing for `.graceChord` fails it immediately.
    ///
    /// The grace sits at G4, INSIDE the staff on purpose: an out-of-staff
    /// grace would also emit `.ledgerLine` elements, which the Canvas
    /// renderer already drew, so the ledger ink alone could carry the
    /// assertion and the notehead itself would go untested.
    @Suite("Canvas grace-chord ink")
    struct CanvasGraceChordInkTests {
        private let _installApple = TestSupport.installApple

        /// A bare `withGraces > plain` does NOT catch the bug, and this
        /// was verified rather than assumed: with `.graceChord` stubbed
        /// back to `break` the grace score still measures 43 dark pixels
        /// MORE than the plain one. A grace reserves horizontal space
        /// whether or not anything is drawn in it, which widens the
        /// measure and lengthens the staff lines — so the layout shift
        /// alone satisfies "strictly greater".
        ///
        /// Measured for this fixture's four acciaccaturas at scale 3:
        ///   renderer correct  → +709 (13399 → 14108)
        ///   `.graceChord` off → +43  (13399 → 13442)
        /// The threshold sits between the two, an order of magnitude
        /// above the layout noise and well under the glyph ink.
        private static let minimumGraceInk = 400

        @MainActor
        @Test("Grace chords put ink on the exported page")
        func graceChordsRenderInPDFExport() throws {
            guard #available(macOS 15.0, *) else { return }
            let plain = try CanvasInkProbe.ink(of: Self.score(withGraces: false))
            let withGraces = try CanvasInkProbe.ink(of: Self.score(withGraces: true))
            #expect(plain > 0, "the plain score should render some ink")
            #expect(
                withGraces - plain > Self.minimumGraceInk,
                """
                Canvas drew little or no grace-chord ink: \
                dark pixels with graces = \(withGraces), \
                without = \(plain), delta = \(withGraces - plain) \
                (expected > \(Self.minimumGraceInk)).
                """,
            )
        }

        // MARK: - Fixtures

        /// One 4/4 measure of four B4 quarter notes, optionally each
        /// preceded by a G4 acciaccatura.
        private static func score(withGraces: Bool) -> Score {
            let grace = GraceChord(
                graceType: .acciaccatura,
                duration: .eighth,
                // G4 — second line from the bottom of a treble staff, so
                // no ledger line is involved.
                notes: ChordNotes([Note(pitch: 67, tpc: 15)]),
            )
            let chord = Chord(
                duration: .quarter,
                // B4 — middle line, also clear of any ledger.
                notes: ChordNotes([Note(pitch: 71, tpc: 19)]),
                graceNotesBefore: withGraces ? [grace] : [],
                graceNotesAfter: [],
            )
            let measure = Measure(voices: [Voice(elements: [
                .chord(chord), .chord(chord), .chord(chord), .chord(chord),
            ])])
            return Score(
                division: 480,
                parts: [Part(
                    id: "1",
                    instrument: Instrument(id: "x"),
                    staves: [Staff(measures: [measure])],
                )],
            )
        }
    }
#endif
