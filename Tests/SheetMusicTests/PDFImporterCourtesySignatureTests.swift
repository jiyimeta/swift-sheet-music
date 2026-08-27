#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    /// A courtesy (予備) key / time signature drawn at the END of a measure
    /// announces the NEXT measure's change. The leading readers must not take
    /// it as the measure's own — including when the measure holds no
    /// noteheads at all, which is how the bug slipped through: the leading
    /// region used to end at the first NOTEHEAD, so an empty bar's scan ran
    /// past its rest all the way to the courtesy.
    struct PDFImporterCourtesySignatureTests {
        private func synthStaff() -> SheetMusicPDF.Staff {
            SheetMusicPDF.Staff(
                pageIndex: 0,
                yLines: [490, 495, 500, 505, 510],
                xRange: 50 ... 550,
                barlineCandidates: [],
            )
        }

        private func classified(
            _ semantic: SMuFLSemantic, x: CGFloat, y: CGFloat = 500,
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
            _ xRange: ClosedRange<CGFloat>, _ glyphs: [ClassifiedGlyph],
        ) -> ImportMeasure {
            ImportMeasure(
                xRange: xRange, glyphs: glyphs,
                leadingBarline: nil, trailingBarline: nil,
            )
        }

        private func times(_ events: [ScoreStateEvent]) -> [(TimeSignature, Int)] {
            events.compactMap {
                if case let .timeSignature(t, atMeasureIndex: i) = $0 { (t, i) } else { nil }
            }
        }

        /// A 2/4 courtesy at the right edge of an EMPTY (rest-only) measure
        /// must not become that measure's time signature.
        @Test func courtesyTimeAfterRestIsNotTheMeasuresOwn() {
            let m0 = measure(50 ... 300, [
                classified(.rest(.whole), x: 150),
                // Courtesy "2 over 4" announcing the next system's change.
                classified(.timeSignatureDigit(2), x: 280, y: 506),
                classified(.timeSignatureDigit(4), x: 280, y: 494),
            ])
            let staff = ImportStaff(staff: synthStaff(), measures: [m0])
            let events = PDFImporter.scoreStateEvents(staff: staff, texts: [])
            #expect(times(events).isEmpty)
        }

        /// The same courtesy after a NOTEHEAD was already handled; pin it so
        /// the two paths can't diverge again.
        @Test func courtesyTimeAfterNoteheadIsNotTheMeasuresOwn() {
            let m0 = measure(50 ... 300, [
                classified(.noteheadBlack, x: 150),
                classified(.timeSignatureDigit(2), x: 280, y: 506),
                classified(.timeSignatureDigit(4), x: 280, y: 494),
            ])
            let staff = ImportStaff(staff: synthStaff(), measures: [m0])
            let events = PDFImporter.scoreStateEvents(staff: staff, texts: [])
            #expect(times(events).isEmpty)
        }

        /// A genuine LEADING time signature — before the measure's rest — is
        /// still read. Pins that the fix narrowed the region, not closed it.
        @Test func leadingTimeBeforeARestIsStillRead() {
            let m0 = measure(50 ... 300, [
                classified(.timeSignatureDigit(2), x: 60, y: 506),
                classified(.timeSignatureDigit(4), x: 60, y: 494),
                classified(.rest(.whole), x: 150),
            ])
            let staff = ImportStaff(staff: synthStaff(), measures: [m0])
            let read = times(PDFImporter.scoreStateEvents(staff: staff, texts: []))
            #expect(read.count == 1)
            #expect(read.first?.0.numerator == 2)
            #expect(read.first?.0.denominator == 4)
            #expect(read.first?.1 == 0)
        }

        /// The CLEF reader deliberately keeps the older, wider NOTEHEAD
        /// boundary: a clef drawn after a rest is still read as that
        /// measure's own. Narrowing it to match the key / time readers
        /// measured WORSE on the corpus (カゲロウ's clef running-match
        /// 1339 → 1338/1536), because a clef following a rest in a rest-only
        /// measure is more often that measure's late-drawn clef than a
        /// courtesy for the next one. Clefs also already have a dedicated
        /// courtesy path (`readTrailingClef`), which the key / time readers
        /// lacked for this case. Pinned so a later "unify the boundaries"
        /// cleanup can't silently regress that.
        @Test func clefAfterARestIsStillTheMeasuresOwn() {
            let m0 = measure(50 ... 300, [
                classified(.rest(.whole), x: 150),
                classified(.clefF, x: 280),
            ])
            let m1 = measure(300 ... 550, [classified(.noteheadBlack, x: 350)])
            let staff = ImportStaff(staff: synthStaff(), measures: [m0, m1])
            let events = PDFImporter.scoreStateEvents(staff: staff, texts: [])
            let clefs: [(Clef, Int)] = events.compactMap {
                if case let .clefChange(c, atMeasureIndex: i) = $0 { (c, i) } else { nil }
            }
            #expect(clefs.contains { $0.0.concertClefType == "F" && $0.1 == 0 })
        }
    }
#endif
