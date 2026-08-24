#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    /// A voice whose whole content is one whole-rest glyph is a MEASURE rest,
    /// not a literal whole note. MuseScore engraves a full-measure rest with
    /// `restWhole` in every time signature, so the glyph alone cannot tell a
    /// 2/4 empty bar from a 4/4 one — the bar length does.
    @MainActor struct PDFImporterMeasureRestTests {
        private func rest(
            _ duration: NoteDuration, x: CGFloat = 100, y: CGFloat = 500,
        ) -> RhythmElement {
            RhythmElement(
                chord: Chord(duration: duration, notes: []),
                x: x, y: y, stemDirection: nil, beamGroup: nil,
            )
        }

        private func note(
            _ duration: NoteDuration, x: CGFloat, y: CGFloat = 500,
        ) -> RhythmElement {
            RhythmElement(
                chord: Chord(
                    duration: duration,
                    notes: [Note(pitch: 71, tpc: 14)],
                ),
                x: x, y: y, stemDirection: .down, beamGroup: nil,
            )
        }

        private func reconcile(
            _ elements: [RhythmElement], _ n: Int, _ d: Int,
        ) -> [RhythmElement] {
            PDFImporter.reconcileMeasureDurations(
                elements: elements,
                timeSignature: TimeSignature(numerator: n, denominator: d),
                spatium: 5,
            )
        }

        @Test func loneWholeRestBecomesMeasureRestInShortBar() {
            let out = reconcile([rest(.whole)], 2, 4)
            #expect(out.count == 1)
            #expect(out[0].chord.duration == .measure)
        }

        @Test func loneWholeRestBecomesMeasureRestInCommonTime() {
            // Same glyph, same reading: MuseScore spells a 4/4 empty bar
            // `<durationType>measure</durationType>` too, so matching it keeps
            // the PDF import byte-identical to the mscz ground truth.
            let out = reconcile([rest(.whole)], 4, 4)
            #expect(out[0].chord.duration == .measure)
        }

        @Test func loneWholeRestBecomesMeasureRestInCompoundBar() {
            let out = reconcile([rest(.whole)], 6, 8)
            #expect(out[0].chord.duration == .measure)
        }

        @Test func wholeRestBesideOtherContentStaysLiteral() {
            // 6/4 = whole + half. The whole rest is a genuine whole rest here
            // (it does not fill the bar), so it must keep its typed duration.
            let out = reconcile([rest(.whole, x: 100), note(.half, x: 200)], 6, 4)
            #expect(out[0].chord.duration == .whole)
            #expect(out[1].chord.duration == .half)
        }

        @Test func loneShorterRestIsNotAMeasureRest() {
            // A lone quarter rest in a 2/4 bar is an under-full voice, not the
            // measure-rest convention — reconciliation must not rewrite it.
            let out = reconcile([rest(.quarter)], 2, 4)
            #expect(out[0].chord.duration == .quarter)
        }

        @Test func perVoiceMeasureRestIsNormalized() {
            // Two voices at a coincident onset: the upper voice is a
            // full-measure rest, the lower voice carries the notes. Only the
            // rest voice is rewritten.
            let out = reconcile(
                [
                    rest(.whole, x: 100, y: 560),
                    note(.quarter, x: 100, y: 440),
                    note(.quarter, x: 160, y: 440),
                ],
                2, 4,
            )
            #expect(out[0].chord.duration == .measure)
            #expect(out[1].chord.duration == .quarter)
            #expect(out[2].chord.duration == .quarter)
        }
    }
#endif
