#if os(macOS)
    import Foundation
    import SheetMusicCore
    import Testing

    /// Presence check for the SwiftUI Canvas renderer's per-staff line
    /// count.
    ///
    /// `StaffRenderer.draw` is the third renderer that had to stop
    /// hardcoding five staff lines, and the only one of the three with no
    /// other coverage: the new `LayoutBridge` stroke-count test pins the
    /// Android bridge, and the corpus pixel gate rasterizes the CALayer
    /// tree (`ScoreLayerBuilder`), but nothing exercises
    /// `ScoreCanvasDrawing.drawSystem` — the path behind PDF export and
    /// `PagedScoreView`. See `CanvasInkProbe` for why that gap is worth
    /// a dedicated suite.
    @Suite("Canvas staff-line ink")
    struct CanvasStaffLineInkTests {
        private let _installApple = TestSupport.installApple

        /// A bare `five > one` would NOT catch the bug, and this was
        /// measured rather than assumed: with `StaffRenderer.draw`'s loop
        /// put back to `0 ..< 5`, the one-line render comes out 55 dark
        /// pixels HEAVIER than the five-line one. Shrinking the staff
        /// still shortens the system, which shifts the adaptive vertical
        /// padding and moves ink around — so the sign of a bare
        /// comparison is decided by layout noise, not by staff lines.
        ///
        /// Measured for this fixture's four measures at scale 3:
        ///   renderer correct  → +7185 (16715 → 9530)
        ///   loop back to five → −55   (16715 → 16770)
        /// The threshold sits between the two: 50× the noise magnitude
        /// and well under the four staff lines' worth of ink.
        private static let minimumInkDrop = 3000

        @MainActor
        @Test("A one-line staff draws four fewer lines on the page")
        func oneLineStaffPutsLessInkOnThePage() throws {
            guard #available(macOS 15.0, *) else { return }
            let five = try CanvasInkProbe.ink(of: Self.score(lineCount: 5))
            let one = try CanvasInkProbe.ink(of: Self.score(lineCount: 1))
            #expect(one > 0, "the one-line score should render some ink")
            #expect(
                five - one > Self.minimumInkDrop,
                """
                Canvas drew a one-line staff with too much ink: \
                five-line = \(five), one-line = \(one), \
                delta = \(five - one) \
                (expected > \(Self.minimumInkDrop)).
                """,
            )
        }

        // MARK: - Fixtures

        /// Four 4/4 measures of four F5 quarters on a single staff whose
        /// line count is `lineCount`.
        ///
        /// F5 is the TOP line of a treble staff (`step` 4), and
        /// `StaffLineGeometry.topStep` is fixed at 4 for every line count
        /// — so the note takes no ledger line at either count and the
        /// staff lines are the only ink that moves. A note below the
        /// staff would not do: shrinking a staff raises its bottom line,
        /// so such a note GAINS ledger lines as `lineCount` drops, and
        /// the ledger ink would fight the assertion.
        private static func score(lineCount: Int) -> Score {
            let chord = Chord(
                duration: .quarter,
                notes: ChordNotes([Note(pitch: 77, tpc: 13)]),
            )
            let measure = Measure(voices: [Voice(elements: [
                .chord(chord), .chord(chord), .chord(chord), .chord(chord),
            ])])
            return Score(
                division: 480,
                parts: [Part(
                    id: "1",
                    instrument: Instrument(id: "x"),
                    staves: [Staff(
                        lineCount: lineCount,
                        measures: [measure, measure, measure, measure],
                    )],
                )],
            )
        }
    }
#endif
