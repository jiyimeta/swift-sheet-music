#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    /// Tempo recovery: a "♩ = NN" marking in the PDF text must land in
    /// `Score.systemMeasures` so playback uses the engraved BPM (not the 120
    /// default). MuseScore emits one TextGlyph per character, so the digits
    /// arrive split and must be merged before parsing. Copyright-clean
    /// synthetic input (same unit style as the other importer tests).
    struct PDFImporterTempoTests {
        private let yLines: [CGFloat] = [490, 495, 500, 505, 510]

        private func system(measureXRanges: [ClosedRange<CGFloat>]) -> ImportSystem {
            let staff = Staff(
                pageIndex: 0, yLines: yLines,
                xRange: 50 ... 550, barlineCandidates: [],
            )
            let measures = measureXRanges.map { xr in
                ImportMeasure(
                    xRange: xr, glyphs: [],
                    leadingBarline: nil, trailingBarline: nil,
                    staffYLines: yLines,
                )
            }
            let importStaff = ImportStaff(staff: staff, measures: measures)
            return ImportSystem(
                pageIndex: 0, yRange: 480 ... 520,
                parts: [ImportPart(staves: [importStaff])],
            )
        }

        private func tg(_ s: String, x: CGFloat, y: CGFloat) -> TextGlyph {
            TextGlyph(
                text: s, fontName: "Edwin", fontSize: 12,
                origin: CGPoint(x: x, y: y), bbox: .zero, pageIndex: 0,
            )
        }

        /// Per-character "= 120" above measure 0 → tempo at measure 0.
        @Test func recoversBpmFromSplitCharacterRun() {
            let sys = system(measureXRanges: [50 ... 300, 300 ... 550])
            // y above the top staff line (510); x within measure 0.
            let texts = [
                tg("=", x: 100, y: 525),
                tg("1", x: 104, y: 525),
                tg("2", x: 108, y: 525),
                tg("0", x: 112, y: 525),
            ]
            let result = PDFImporter.tempoSystemMeasures(
                systems: [sys], texts: texts, measureCount: 2,
            )
            #expect(result.count == 2)
            guard case let .tempo(tempo)? = result.first?.elements.first?.element else {
                Issue.record("no tempo at measure 0")
                return
            }
            #expect(abs(tempo.beatsPerSecond - 120.0 / 60.0) < 0.001)
            // Measure 1 carries no tempo.
            #expect(result[1].elements.isEmpty)
        }

        /// A marking above the second measure maps there, not to measure 0.
        @Test func mapsTempoToTheMeasureItSitsAbove() {
            let sys = system(measureXRanges: [50 ... 300, 300 ... 550])
            let texts = [
                tg("=", x: 320, y: 525),
                tg("9", x: 324, y: 525),
                tg("0", x: 328, y: 525),
            ]
            let result = PDFImporter.tempoSystemMeasures(
                systems: [sys], texts: texts, measureCount: 2,
            )
            #expect(result.first?.elements.isEmpty == true)
            guard case let .tempo(tempo)? = result[1].elements.first?.element else {
                Issue.record("no tempo at measure 1")
                return
            }
            #expect(abs(tempo.beatsPerSecond - 90.0 / 60.0) < 0.001)
        }

        /// No "= NN" text → no tempo (empty system measures).
        @Test func noTempoTextYieldsNone() {
            let sys = system(measureXRanges: [50 ... 550])
            let texts = [tg("L", x: 100, y: 525), tg("a", x: 106, y: 525)]
            let result = PDFImporter.tempoSystemMeasures(
                systems: [sys], texts: texts, measureCount: 1,
            )
            #expect(result.isEmpty)
        }
    }
#endif
