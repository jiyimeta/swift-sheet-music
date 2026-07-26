#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    @MainActor struct PDFImporterRhythmTests {
        // MARK: - Fixtures

        private func notehead(
            x: CGFloat, y: CGFloat = 500,
            kind: SMuFLSemantic = .noteheadBlack,
            midi: Int = 71,
        ) -> (ClassifiedGlyph, PDFImporter.DecodedPitch) {
            let g = ClassifiedGlyph(
                geometry: GlyphGeometry(
                    origin: CGPoint(x: x, y: y), advance: 5,
                    pageIndex: 0, fontSize: 20,
                ),
                semantic: kind,
            )
            let dp = PDFImporter.DecodedPitch(
                midi: midi, tpc: 14,
                noteheadX: x, noteheadY: y, glyph: g,
            )
            return (g, dp)
        }

        private func stem(x: CGFloat, yMin: CGFloat, yMax: CGFloat) -> PathSegment {
            PathSegment(
                kind: .vertical,
                rect: CGRect(x: x, y: yMin, width: 0, height: yMax - yMin),
                lineWidth: 0.5,
                pageIndex: 0,
            )
        }

        private func flag(
            x: CGFloat, y: CGFloat, kind: SMuFLSemantic,
        ) -> ClassifiedGlyph {
            ClassifiedGlyph(
                geometry: GlyphGeometry(
                    origin: CGPoint(x: x, y: y), advance: 5,
                    pageIndex: 0, fontSize: 20,
                ),
                semantic: kind,
            )
        }

        private func dot(x: CGFloat, y: CGFloat) -> ClassifiedGlyph {
            ClassifiedGlyph(
                geometry: GlyphGeometry(
                    origin: CGPoint(x: x, y: y), advance: 5,
                    pageIndex: 0, fontSize: 20,
                ),
                semantic: .augmentationDot,
            )
        }

        private func restGlyph(
            x: CGFloat, y: CGFloat = 500, duration: NoteDuration,
        ) -> ClassifiedGlyph {
            ClassifiedGlyph(
                geometry: GlyphGeometry(
                    origin: CGPoint(x: x, y: y), advance: 5,
                    pageIndex: 0, fontSize: 20,
                ),
                semantic: .rest(duration),
            )
        }

        private func makeMeasure(
            glyphs: [ClassifiedGlyph],
            staffYLines: [CGFloat] = [490, 495, 500, 505, 510],
        ) -> ImportMeasure {
            ImportMeasure(
                xRange: 50 ... 550,
                glyphs: glyphs,
                leadingBarline: nil,
                trailingBarline: nil,
                staffYLines: staffYLines,
            )
        }

        // MARK: - Tests

        @Test func blackNoteheadAloneIsQuarter() {
            let (g, dp) = notehead(x: 100, y: 500)
            let m = makeMeasure(glyphs: [g])
            let stems = [stem(x: 100, yMin: 500, yMax: 530)]
            let rhythm = PDFImporter.decodeRhythm(
                measure: m, decoded: [dp], paths: stems,
            )
            #expect(rhythm.count == 1)
            #expect(rhythm.first?.chord.duration == .quarter)
            #expect(rhythm.first?.chord.notes.count == 1)
            #expect(rhythm.first?.isRest == false)
        }

        @Test func wholeNoteheadIsWhole() {
            let (g, dp) = notehead(x: 100, y: 500, kind: .noteheadWhole)
            let m = makeMeasure(glyphs: [g])
            let rhythm = PDFImporter.decodeRhythm(
                measure: m, decoded: [dp], paths: [],
            )
            #expect(rhythm.count == 1)
            #expect(rhythm.first?.chord.duration == .whole)
            #expect(rhythm.first?.stemDirection == nil)
        }

        @Test func halfNoteheadIsHalf() {
            let (g, dp) = notehead(x: 100, y: 500, kind: .noteheadHalf)
            let m = makeMeasure(glyphs: [g])
            let stems = [stem(x: 100, yMin: 500, yMax: 530)]
            let rhythm = PDFImporter.decodeRhythm(
                measure: m, decoded: [dp], paths: stems,
            )
            #expect(rhythm.count == 1)
            #expect(rhythm.first?.chord.duration == .half)
        }

        @Test func blackPlusOneFlagIsEighth() {
            let (g, dp) = notehead(x: 100, y: 500)
            // Stem extends upward from notehead to y=530. The flag glyph's
            // ORIGIN sits ~12pt above the notehead in MuseScore's real export
            // (R7-calibrated `applyFlags` gate is 4…22pt from the notehead,
            // NOT from the stem end), so the fixture places it at y=512.
            let stems = [stem(x: 100, yMin: 500, yMax: 530)]
            let f = flag(x: 100, y: 512, kind: .flag8thUp)
            let m = makeMeasure(glyphs: [g, f])
            let rhythm = PDFImporter.decodeRhythm(
                measure: m, decoded: [dp], paths: stems,
            )
            #expect(rhythm.count == 1)
            #expect(rhythm.first?.chord.duration == .eighth)
        }

        @Test func blackPlusTwoFlagsIsSixteenth() {
            let (g, dp) = notehead(x: 100, y: 500)
            // Combined 16th flag glyph (single glyph carrying both beam
            // levels) at a realistic ~12pt-above-notehead origin; a separate
            // 8th flag a touch lower, both inside the 4…22pt gate. (R7 stale
            // fixture used y=528/530 ≈ dy 28-30, outside the real flag band.)
            let stems = [stem(x: 100, yMin: 500, yMax: 530)]
            let f1 = flag(x: 100, y: 512, kind: .flag8thUp)
            let f2 = flag(x: 100, y: 514, kind: .flag16thUp)
            let m = makeMeasure(glyphs: [g, f1, f2])
            let rhythm = PDFImporter.decodeRhythm(
                measure: m, decoded: [dp], paths: stems,
            )
            #expect(rhythm.count == 1)
            #expect(rhythm.first?.chord.duration == .sixteenth)
        }

        @Test func blackPlusOneDotIsDottedQuarter() {
            let (g, dp) = notehead(x: 100, y: 500)
            let stems = [stem(x: 100, yMin: 500, yMax: 530)]
            let d = dot(x: 110, y: 500)
            let m = makeMeasure(glyphs: [g, d])
            let rhythm = PDFImporter.decodeRhythm(
                measure: m, decoded: [dp], paths: stems,
            )
            #expect(rhythm.count == 1)
            #expect(rhythm.first?.chord.duration == NoteDuration.quarter.dotted(1))
        }

        @Test func twoNoteheadsOneStemFormOneChord() {
            let (g1, dp1) = notehead(x: 100, y: 495, midi: 67)
            let (g2, dp2) = notehead(x: 100, y: 505, midi: 74)
            let stems = [stem(x: 100, yMin: 495, yMax: 525)]
            let m = makeMeasure(glyphs: [g1, g2])
            let rhythm = PDFImporter.decodeRhythm(
                measure: m, decoded: [dp1, dp2], paths: stems,
            )
            #expect(rhythm.count == 1)
            #expect(rhythm.first?.chord.notes.count == 2)
        }

        @Test func twoNoteheadsAdjacentStemsFormTwoChords() {
            let (g1, dp1) = notehead(x: 100, y: 500, midi: 71)
            let (g2, dp2) = notehead(x: 200, y: 500, midi: 72)
            let stems = [
                stem(x: 100, yMin: 500, yMax: 530),
                stem(x: 200, yMin: 500, yMax: 530),
            ]
            let m = makeMeasure(glyphs: [g1, g2])
            let rhythm = PDFImporter.decodeRhythm(
                measure: m, decoded: [dp1, dp2], paths: stems,
            )
            #expect(rhythm.count == 2)
            #expect(rhythm[0].chord.notes.count == 1)
            #expect(rhythm[1].chord.notes.count == 1)
        }

        @Test func restGlyphProducesRest() {
            let r = restGlyph(x: 100, y: 500, duration: .quarter)
            let m = makeMeasure(glyphs: [r])
            let rhythm = PDFImporter.decodeRhythm(
                measure: m, decoded: [], paths: [],
            )
            #expect(rhythm.count == 1)
            #expect(rhythm.first?.chord.notes.isEmpty == true)
            #expect(rhythm.first?.chord.duration == .quarter)
            #expect(rhythm.first?.isRest == true)
        }
    }
#endif
