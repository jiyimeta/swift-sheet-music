#if os(macOS)
    import CoreGraphics
    import QuartzCore
    import SheetMusicCore
    import SheetMusicLayout
    @testable import SheetMusicUI
    import Testing

    /// The two Apple renderers' half of the barline span.
    ///
    /// `LayoutElement.barLine` carries `halfHeight`, but both renderers
    /// take it as a plain parameter — nothing forces either body to
    /// actually use it, and before this change the ±2 sp was written
    /// down in each independently of the engine. Every layout-level
    /// assertion in `StaffLineCountLayoutTests` passes on a renderer
    /// that keeps deriving the span from `metrics`, because none of
    /// them reaches a renderer at all.
    ///
    /// The CALayer path (`ScoreLayerBuilder.drawBarLine`) is also
    /// covered by the corpus pixel gate, but only for scores that
    /// happen to contain a non-five-line staff. The SwiftUI Canvas path
    /// (`BarLineRenderer`, behind PDF export and `PagedScoreView`) has
    /// no other coverage whatsoever.
    ///
    /// Every half-height under test is deliberately NOT `sp * 2` — a
    /// three-line staff's `sp`, where the old constant draws twice the
    /// stroke. On a ONE-line staff the correct half-height happens to
    /// be 2 sp as well, so that case pins the engine's centering but
    /// cannot discriminate a renderer.
    @Suite("Bar line span — renderers")
    struct BarLineSpanRendererTests {
        @Test("drawBarLine strokes origin.y ± halfHeight")
        func strokeFollowsTheSuppliedHalfHeight() throws {
            guard #available(macOS 15.0, *) else { return }
            let metrics = StaffMetrics(staffSize: 28) // sp = 7
            let originY: CGFloat = 100
            let halfHeight = metrics.sp // a three-line staff's span

            let parent = CALayer()
            ScoreLayerBuilder.drawBarLine(
                subtype: nil,
                origin: CGPoint(x: 50, y: originY),
                halfHeight: halfHeight,
                metrics: metrics,
                height: 0,
                into: parent,
            )

            let shape = try #require(
                parent.sublayers?.compactMap { $0 as? CAShapeLayer }.first,
            )
            let box = try #require(shape.path?.boundingBox)
            #expect(abs(box.height - halfHeight * 2) < 0.001)
            // `strokeLayer` flips Y for the platform, so compare the
            // stroke's center to `originY` by magnitude rather than
            // assuming a direction.
            #expect(abs(abs(box.midY) - originY) < 0.001)
        }

        // MARK: - SwiftUI Canvas

        /// The Canvas renderer (`BarLineRenderer.draw`) is the third
        /// place the ±2 sp used to be written down, and the one with no
        /// other coverage at all: the corpus pixel gate rasterizes the
        /// CALayer tree, not this path, which also backs PDF export and
        /// `PagedScoreView`.
        ///
        /// An ink COUNT cannot see this defect on a one-line staff — the
        /// mis-centered stroke is the same 4 sp of ink, merely
        /// translated — so the probe measures the ink's vertical EXTENT
        /// in the terminal barline's own column instead. That column is
        /// at the system's RIGHT edge, so the (separately unfixed)
        /// system-start line at the left edge cannot contaminate it.
        ///
        /// Measured at the default 3× raster: correct → 30 px one side,
        /// 28 px the other (the 2 px is the antialiased staff line
        /// rounding to one row or the next). With the ENGINE reverted
        /// the barline hangs entirely below the line: 0 px and 58 px.
        /// The tolerance sits far below that gap on purpose.
        ///
        /// Note this does NOT catch a renderer that ignores
        /// `halfHeight` — on one line the correct half-height is 2 sp,
        /// the same as the old constant. That is
        /// `canvasBarLineHeightFollowsLineCount`'s job.
        @MainActor
        @Test("Canvas centers a one-line staff's barline on its line")
        func canvasBarLineIsCenteredOnTheSingleLine() throws {
            guard #available(macOS 15.0, *) else { return }
            let raster = try CanvasInkProbe.raster(of: Self.score(lineCount: 1))
            let staffLineY = try #require(raster.busiestRow)
            let edge = try #require(raster.rightmostDarkColumn)
            // One column in from the extreme edge, so an antialiased
            // half-covered pixel cannot shorten the measured run.
            let ys = raster.darkYs(atX: edge - 1)
            let near = try #require(ys.min())
            let far = try #require(ys.max())
            let sideA = staffLineY - near
            let sideB = far - staffLineY

            #expect(
                min(sideA, sideB) > 10,
                """
                the barline should straddle the single staff line, but \
                one side is \(sideA) px and the other \(sideB) px \
                (line at y=\(staffLineY), run \(near)…\(far) at x=\(edge - 1)).
                """,
            )
            #expect(
                abs(sideA - sideB) <= 5,
                """
                the barline is not centered on the single staff line: \
                \(sideA) px on one side, \(sideB) px on the other \
                (line at y=\(staffLineY), run \(near)…\(far) at x=\(edge - 1)).
                """,
            )
        }

        /// Vertical extent of the terminal barline's ink, in raster px.
        @MainActor
        @available(macOS 15.0, *)
        private static func canvasBarLineHeight(lineCount: Int) throws -> Int {
            let raster = try CanvasInkProbe.raster(of: score(lineCount: lineCount))
            let edge = try #require(raster.rightmostDarkColumn)
            let ys = raster.darkYs(atX: edge - 1)
            let near = try #require(ys.min())
            let far = try #require(ys.max())
            return far - near
        }

        /// The symmetry check above cannot catch a renderer that ignores
        /// `halfHeight`, because on a ONE-line staff the correct
        /// half-height IS 2 sp — the old constant. Only a line count
        /// whose span differs from 4 sp discriminates, and three lines
        /// is the smallest such case: 2 sp of barline where the old
        /// constant draws 4 sp, i.e. literally half the stroke.
        ///
        /// Pinned as a ratio against the five-line render rather than in
        /// absolute px, so it survives a change of page size, staff size
        /// or raster scale — the five-line barline is 4 sp by
        /// definition, so it calibrates sp for the three-line one.
        ///
        /// Measured at the default 3× raster: correct → 30 px against
        /// 60 px, `|three*2 − five| == 0`. With `BarLineRenderer`'s span
        /// put back to `metrics.sp * 2` → 58 px against 60 px, i.e. 56.
        @MainActor
        @Test("Canvas draws a three-line staff's barline at half height")
        func canvasBarLineHeightFollowsLineCount() throws {
            guard #available(macOS 15.0, *) else { return }
            let five = try Self.canvasBarLineHeight(lineCount: 5)
            let three = try Self.canvasBarLineHeight(lineCount: 3)
            #expect(five > 20, "five-line barline measured \(five) px")
            #expect(
                abs(three * 2 - five) <= 3,
                """
                a three-line staff's barline should be half the \
                five-line one (2 sp vs 4 sp), but measured \(three) px \
                against \(five) px.
                """,
            )
        }

        // MARK: - Fixtures

        /// One staff of `lineCount` lines, one measure, one F5 quarter.
        ///
        /// F5 is the treble staff's TOP line (`step` 4), and
        /// `StaffLineGeometry.topStep` is fixed at 4 for every line
        /// count, so the note draws no ledger line at any count.
        private static func score(lineCount: Int) -> Score {
            let measure = Measure(voices: [Voice(elements: [
                .clef(Clef(concertClefType: "G")),
                .timeSignature(TimeSignature(numerator: 4, denominator: 4)),
                .chord(Chord(
                    duration: .quarter,
                    notes: [Note(pitch: 77, tpc: 13)],
                )),
            ])])
            return Score(
                division: 480,
                parts: [Part(
                    id: "P1",
                    instrument: Instrument(id: "perc"),
                    staves: [Staff(lineCount: lineCount, measures: [measure])],
                )],
            )
        }
    }
#endif
