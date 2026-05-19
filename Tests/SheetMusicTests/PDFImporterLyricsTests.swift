#if !os(Android)
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    @MainActor struct PDFImporterLyricsTests {
        // MARK: - Fixtures

        private func textGlyph(
            _ text: String, x: CGFloat, y: CGFloat,
        ) -> TextGlyph {
            TextGlyph(
                text: text,
                fontName: "Helvetica",
                fontSize: 10,
                origin: CGPoint(x: x, y: y),
                bbox: CGRect(x: x, y: y, width: 20, height: 10),
                pageIndex: 0,
            )
        }

        private func chordElement(
            x: CGFloat, midi: Int = 60,
        ) -> RhythmElement {
            RhythmElement(
                chord: Chord(
                    duration: .quarter,
                    notes: ChordNotes([Note(pitch: midi, tpc: 14)]),
                ),
                x: x,
                y: 500,
                stemDirection: .up,
                beamGroup: nil,
            )
        }

        /// Five staff lines, ascending y. The "bottom" of the staff in
        /// PDF y-up coordinates is `staffYLines[0] = 490`. Lyrics live
        /// just below that.
        private let staffYLines: [CGFloat] = [490, 495, 500, 505, 510]

        // MARK: - Tests

        @Test func singleSyllableAttachesToNearestNote() {
            let elements = [chordElement(x: 100)]
            let texts = [textGlyph("Hi", x: 100, y: 480)]
            let out = PDFImporter.attachLyrics(
                elements: elements,
                texts: texts,
                staffYLines: staffYLines,
                pageIndex: 0,
            )
            #expect(out.count == 1)
            #expect(out[0].chord.lyrics == [Lyric(text: "Hi", syllabic: .single)])
        }

        @Test func hyphenStartsBeginMiddleEnd() {
            let elements = [
                chordElement(x: 100),
                chordElement(x: 200),
            ]
            let texts = [
                textGlyph("Hap-", x: 100, y: 480),
                textGlyph("py", x: 200, y: 480),
            ]
            let out = PDFImporter.attachLyrics(
                elements: elements,
                texts: texts,
                staffYLines: staffYLines,
                pageIndex: 0,
            )
            #expect(out[0].chord.lyrics == [Lyric(text: "Hap", syllabic: .begin)])
            #expect(out[1].chord.lyrics == [Lyric(text: "py", syllabic: .end)])
        }

        @Test func fourSyllableHyphenChain() {
            let elements = [
                chordElement(x: 100),
                chordElement(x: 200),
                chordElement(x: 300),
                chordElement(x: 400),
            ]
            let texts = [
                textGlyph("Hap-", x: 100, y: 480),
                textGlyph("py", x: 200, y: 480),
                textGlyph("birth-", x: 300, y: 480),
                textGlyph("day", x: 400, y: 480),
            ]
            let out = PDFImporter.attachLyrics(
                elements: elements,
                texts: texts,
                staffYLines: staffYLines,
                pageIndex: 0,
            )
            #expect(out[0].chord.lyrics == [Lyric(text: "Hap", syllabic: .begin)])
            #expect(out[1].chord.lyrics == [Lyric(text: "py", syllabic: .end)])
            #expect(out[2].chord.lyrics == [Lyric(text: "birth", syllabic: .begin)])
            #expect(out[3].chord.lyrics == [Lyric(text: "day", syllabic: .end)])
        }

        @Test func underscoreExtendsMelisma() {
            let elements = [
                chordElement(x: 100),
                chordElement(x: 200),
            ]
            let texts = [
                textGlyph("Sing", x: 100, y: 480),
                textGlyph("_", x: 200, y: 480),
            ]
            let out = PDFImporter.attachLyrics(
                elements: elements,
                texts: texts,
                staffYLines: staffYLines,
                pageIndex: 0,
            )
            // First chord still gets a single syllable; underscore is not
            // attached as a new syllable. (Melisma `ticks` updating is
            // deferred to Task 13 assembleScore.)
            #expect(out[0].chord.lyrics.count == 1)
            #expect(out[0].chord.lyrics[0].text == "Sing")
            #expect(out[0].chord.lyrics[0].syllabic == .single)
            #expect(out[1].chord.lyrics.isEmpty)
        }

        @Test func textOutsideYWindowIsIgnored() {
            let elements = [chordElement(x: 100)]
            // y=300 is far above the staff bottom (490) — way outside the
            // four-line-spacing lyric band below it.
            let texts = [textGlyph("Nope", x: 100, y: 300)]
            let out = PDFImporter.attachLyrics(
                elements: elements,
                texts: texts,
                staffYLines: staffYLines,
                pageIndex: 0,
            )
            #expect(out[0].chord.lyrics.isEmpty)
        }
    }
#endif
