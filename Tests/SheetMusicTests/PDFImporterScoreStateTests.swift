#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    struct PDFImporterScoreStateTests {
        private func synthStaff() -> SheetMusicPDF.Staff {
            SheetMusicPDF.Staff(
                pageIndex: 0,
                yLines: [490, 495, 500, 505, 510],
                xRange: 50 ... 550,
                barlineCandidates: [],
            )
        }

        private func classified(
            _ semantic: SMuFLSemantic, x: CGFloat, y: CGFloat,
        ) -> ClassifiedGlyph {
            ClassifiedGlyph(
                geometry: GlyphGeometry(
                    origin: CGPoint(x: x, y: y), advance: 5,
                    pageIndex: 0, fontSize: 20,
                ),
                semantic: semantic,
            )
        }

        private func measure(
            _ xRange: ClosedRange<CGFloat>, glyphs: [ClassifiedGlyph],
        ) -> ImportMeasure {
            ImportMeasure(
                xRange: xRange, glyphs: glyphs,
                leadingBarline: nil, trailingBarline: nil,
            )
        }

        private func importStaff(measures: [ImportMeasure]) -> ImportStaff {
            ImportStaff(staff: synthStaff(), measures: measures)
        }

        private func clefChange(_ events: [ScoreStateEvent]) -> (Clef, Int)? {
            for e in events {
                if case let .clefChange(c, atMeasureIndex: i) = e { return (c, i) }
            }
            return nil
        }

        private func clefChanges(_ events: [ScoreStateEvent]) -> [(Clef, Int)] {
            events.compactMap {
                if case let .clefChange(c, atMeasureIndex: i) = $0 { (c, i) } else { nil }
            }
        }

        private func keySig(_ events: [ScoreStateEvent]) -> (KeySignature, Int)? {
            for e in events {
                if case let .keySignature(k, atMeasureIndex: i) = e { return (k, i) }
            }
            return nil
        }

        private func timeSig(_ events: [ScoreStateEvent]) -> (TimeSignature, Int)? {
            for e in events {
                if case let .timeSignature(t, atMeasureIndex: i) = e { return (t, i) }
            }
            return nil
        }

        @Test func extractsLeadingTrebleClef() {
            let m0 = measure(50 ... 550, glyphs: [classified(.clefG, x: 60, y: 500)])
            let staff = importStaff(measures: [m0])
            let events = PDFImporter.scoreStateEvents(staff: staff, texts: [])
            let result = clefChange(events)
            #expect(result?.0.concertClefType == "G")
            #expect(result?.1 == 0)
        }

        @Test func extractsLeadingBassClef() {
            let m0 = measure(50 ... 550, glyphs: [classified(.clefF, x: 60, y: 500)])
            let staff = importStaff(measures: [m0])
            let events = PDFImporter.scoreStateEvents(staff: staff, texts: [])
            let result = clefChange(events)
            #expect(result?.0.concertClefType == "F")
            #expect(result?.1 == 0)
        }

        @Test func extractsCommonTimeSignature() {
            let m0 = measure(50 ... 550, glyphs: [
                classified(.timeSignatureCommon, x: 80, y: 500),
            ])
            let staff = importStaff(measures: [m0])
            let events = PDFImporter.scoreStateEvents(staff: staff, texts: [])
            let result = timeSig(events)
            // The page drew a C, so the imported score declares a C — not a 4 over a 4 that happens to
            // last as long.
            #expect(result?.0 == TimeSignature(numerator: 4, denominator: 4, symbol: .common))
            #expect(result?.1 == 0)
        }

        @Test func extractsCutTimeSignature() {
            let m0 = measure(50 ... 550, glyphs: [
                classified(.timeSignatureCutTime, x: 80, y: 500),
            ])
            let staff = importStaff(measures: [m0])
            let events = PDFImporter.scoreStateEvents(staff: staff, texts: [])
            let result = timeSig(events)
            #expect(result?.0 == TimeSignature(numerator: 2, denominator: 2, symbol: .cutCommon))
            #expect(result?.1 == 0)
        }

        @Test func extractsStackedTimeSignature() {
            // 6 at higher y (510), 8 at lower y (490), same x.
            let m0 = measure(50 ... 550, glyphs: [
                classified(.timeSignatureDigit(6), x: 80, y: 510),
                classified(.timeSignatureDigit(8), x: 80, y: 490),
            ])
            let staff = importStaff(measures: [m0])
            let events = PDFImporter.scoreStateEvents(staff: staff, texts: [])
            let result = timeSig(events)
            #expect(result?.0 == TimeSignature(numerator: 6, denominator: 8))
        }

        @Test func extractsKeySignatureFourSharps() {
            let m0 = measure(50 ... 550, glyphs: [
                classified(.clefG, x: 60, y: 500),
                classified(.accidentalSharp, x: 80, y: 500),
                classified(.accidentalSharp, x: 86, y: 502),
                classified(.accidentalSharp, x: 92, y: 498),
                classified(.accidentalSharp, x: 98, y: 504),
            ])
            let staff = importStaff(measures: [m0])
            let events = PDFImporter.scoreStateEvents(staff: staff, texts: [])
            let result = keySig(events)
            #expect(result?.0.concertKey == 4)
            #expect(result?.1 == 0)
        }

        @Test func extractsKeySignatureTwoFlats() {
            let m0 = measure(50 ... 550, glyphs: [
                classified(.clefG, x: 60, y: 500),
                classified(.accidentalFlat, x: 80, y: 500),
                classified(.accidentalFlat, x: 86, y: 502),
            ])
            let staff = importStaff(measures: [m0])
            let events = PDFImporter.scoreStateEvents(staff: staff, texts: [])
            let result = keySig(events)
            #expect(result?.0.concertKey == -2)
        }

        @Test func noKeySignatureEventForCMajor() {
            let m0 = measure(50 ... 550, glyphs: [
                classified(.clefG, x: 60, y: 500),
            ])
            let staff = importStaff(measures: [m0])
            let events = PDFImporter.scoreStateEvents(staff: staff, texts: [])
            #expect(keySig(events) == nil)
        }

        @Test func clefThenKeyThenTimeOrder() {
            let m0 = measure(50 ... 550, glyphs: [
                classified(.clefG, x: 60, y: 500),
                classified(.accidentalSharp, x: 80, y: 500),
                classified(.timeSignatureCommon, x: 100, y: 500),
            ])
            let staff = importStaff(measures: [m0])
            let events = PDFImporter.scoreStateEvents(staff: staff, texts: [])
            #expect(events.count == 3)
            if case .clefChange = events[0] {} else {
                Issue.record("expected clefChange first; got \(events[0])")
            }
            if case .keySignature = events[1] {} else {
                Issue.record("expected keySignature second; got \(events[1])")
            }
            if case .timeSignature = events[2] {} else {
                Issue.record("expected timeSignature third; got \(events[2])")
            }
        }

        @Test func clefAfterFirstMeasureIsAlsoEmitted() {
            let m0 = measure(50 ... 300, glyphs: [classified(.clefG, x: 60, y: 500)])
            let m1 = measure(300 ... 550, glyphs: [classified(.clefF, x: 320, y: 500)])
            let staff = importStaff(measures: [m0, m1])
            let events = PDFImporter.scoreStateEvents(staff: staff, texts: [])
            let clefs = clefChanges(events)
            #expect(clefs.count == 2)
            #expect(clefs[0].0.concertClefType == "G")
            #expect(clefs[0].1 == 0)
            #expect(clefs[1].0.concertClefType == "F")
            #expect(clefs[1].1 == 1)
        }
    }
#endif
