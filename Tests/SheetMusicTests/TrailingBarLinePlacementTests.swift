#if canImport(CoreGraphics)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicLayout
    import Testing

    @Suite("Trailing barline placement")
    struct TrailingBarLinePlacementTests {
        /// Regression: an explicit `<BarLine subtype="double">` at the end
        /// of a voice was being placed near the start of the measure
        /// because `tickCursor` sits at the measure's end tick — a tick
        /// that has no entry in `tickColumns` (which only carries
        /// chord/rest start ticks). The fallback path then anchored the
        /// bar to `contentStartX + sp` (≈ the measure header), so
        /// `LayoutSystem.trailingBarLine` returned that early X and the
        /// staff lines were clipped well short of the measure's right
        /// edge — the staff "vanished" for most of the bar before the
        /// double-bar.
        @Test
        func explicitDoubleBarLandsAtMeasureEnd() throws {
            guard #available(macOS 15.0, iOS 16.0, *) else { return }
            let chord = Chord(
                duration: .whole, notes: [Note(pitch: 60, tpc: 14)],
            )
            let measure = Measure(voices: [Voice(elements: [
                .chord(chord),
                .barLine(BarLine(subtype: "double")),
            ])])
            let staff = Staff(measures: [measure])
            let score = Score(
                division: 480,
                parts: [Part(
                    id: "1",
                    instrument: Instrument(id: "x"),
                    staves: [staff],
                )],
            )
            let doc = LayoutEngine.layout(
                score: score, options: .init(), availableWidth: 800,
            )
            let system = try #require(doc.systems.first)
            let trailing = try #require(system.trailingBarLine)
            #expect(trailing.subtype == "double")
            // The trailing bar should sit one half-spatium inside the
            // last measure's right edge — the same anchor the implicit
            // (synthesised) trailing barline uses.
            let lastMeasure = try #require(system.measures.last)
            let expectedX = lastMeasure.origin.x
                + lastMeasure.width - system.sp / 2
            #expect(abs(trailing.x - expectedX) < 0.001)
        }
    }
#endif
