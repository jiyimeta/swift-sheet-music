#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    import SheetMusicCore
    @testable import SheetMusicPDF
    import Testing

    /// The ANCHORED key reader — the ladder path in `PDFImporter+KeyReader`.
    ///
    /// `PDFImporterScoreStateTests`' key cases all leave `ImportMeasure`'s
    /// `staffYLines` at its default `[]`, which makes `staffAnchor` return nil
    /// and routes them through `readKeyLegacy` instead. So the ladder — the
    /// path every real score takes — had no direct unit coverage until this
    /// suite. Every measure here supplies staff lines.
    struct PDFImporterKeyLadderTests {
        static let yLines: [CGFloat] = [490, 495, 500, 505, 510]
        /// `staffAnchor` derives `lineSpacing` from the lines above, and a
        /// diatonic step is half of it.
        static let halfStep: CGFloat = 2.5
        static let bottomY: CGFloat = 490

        /// y for a position `sa` diatonic steps above the bottom staff line —
        /// the same quantity `readKey` recovers by rounding.
        static func y(sa: Int) -> CGFloat {
            bottomY + CGFloat(sa) * halfStep
        }

        static func glyph(_ semantic: SMuFLSemantic, x: CGFloat, sa: Int) -> ClassifiedGlyph {
            ClassifiedGlyph(
                geometry: GlyphGeometry(
                    origin: CGPoint(x: x, y: y(sa: sa)), advance: 5,
                    pageIndex: 0, fontSize: 20,
                ),
                semantic: semantic,
            )
        }

        static func staff(_ glyphs: [ClassifiedGlyph]) -> ImportStaff {
            ImportStaff(
                staff: SheetMusicPDF.Staff(
                    pageIndex: 0, yLines: yLines, xRange: 50 ... 550, barlineCandidates: [],
                ),
                measures: [ImportMeasure(
                    xRange: 50 ... 550, glyphs: glyphs,
                    leadingBarline: nil, trailingBarline: nil, staffYLines: yLines,
                )],
            )
        }

        static func key(_ events: [ScoreStateEvent]) -> KeySignature? {
            for event in events {
                if case let .keySignature(k, atMeasureIndex: _) = event { return k }
            }
            return nil
        }

        /// Treble flats engrave at `sa` 4, 7, 3, 6, 2, 5, 1 (B, E, A, D, G, C, F
        /// counted in diatonic steps above the bottom line, E4).
        static let flatLadder = [4, 7, 3, 6, 2, 5, 1]

        static func flatBlock(_ count: Int, offsetBy shift: Int = 0) -> [ClassifiedGlyph] {
            [glyph(.clefG, x: 60, sa: 4)] + (0 ..< count).map {
                glyph(.accidentalFlat, x: 80 + CGFloat($0) * 6, sa: flatLadder[$0] + shift)
            }
        }

        @Test func aBlockOnTheLadderReadsAsThatKey() {
            let events = PDFImporter.scoreStateEvents(staff: Self.staff(Self.flatBlock(3)), texts: [])
            #expect(Self.key(events)?.concertKey == -3)
        }

        /// The gate this suite exists for: `ladderPrefixCount` compares the
        /// rounded step index with `==`, so an accidental landing one diatonic
        /// step off its canonical position does not weaken the match — it ends
        /// it. A vector glyph's origin is the font's own, so this never fires
        /// there; a detector's origin carries error, and half a line spacing
        /// of it is the whole difference between a key and no key.
        @Test func oneStepOffTheLadderIsNoKeyAtAll() {
            let events = PDFImporter.scoreStateEvents(
                staff: Self.staff(Self.flatBlock(3, offsetBy: 1)), texts: [],
            )
            #expect(Self.key(events) == nil)
        }

        /// And the truncation is a PREFIX: a block whose first two positions
        /// are right and whose third is off reads as a two-flat key, which is
        /// worse than none — every note of the third flat's pitch class is
        /// then wrong, with nothing in the score to say so.
        @Test func aLateMismatchTruncatesTheKeyRatherThanRejectingIt() {
            var glyphs = Self.flatBlock(3)
            glyphs[3] = Self.glyph(.accidentalFlat, x: 92, sa: Self.flatLadder[2] + 1)
            let events = PDFImporter.scoreStateEvents(staff: Self.staff(glyphs), texts: [])
            #expect(Self.key(events)?.concertKey == -2)
        }

        static func diagnostics(_ glyphs: [ClassifiedGlyph]) -> [PDFImportDiagnostic] {
            var collected: [PDFImportDiagnostic] = []
            _ = PDFImporter.scoreStateEvents(
                staff: staff(glyphs), texts: [],
                diagnostics: { collected.append($0) }, location: "page 0, staff 0",
            )
            return collected
        }

        /// Both refusals above are SILENT today: the key is simply absent, or
        /// quietly short, and nothing in the diagnostics says a block was
        /// seen and turned down. That is the drop this repository refuses to
        /// ship — a reader looking at a scan with the wrong key has no way to
        /// learn that the accidentals were read and rejected on position.
        @Test func arefusedBlockSaysWhatItSawAndWhatItExpected() {
            let refused = Self.diagnostics(Self.flatBlock(3, offsetBy: 1))
            #expect(refused.count == 1)
            #expect(refused.first?.message.contains("key signature") == true)
            // The observed positions and the expected ladder both, since the
            // difference between them is the whole diagnosis.
            let context = refused.first?.context ?? ""
            #expect(context.contains("seen [5,8,4]"))
            #expect(context.contains("ladder [4,7,3]"))
        }

        @Test func aPartiallyMatchedBlockIsAlsoReported() {
            var glyphs = Self.flatBlock(3)
            glyphs[3] = Self.glyph(.accidentalFlat, x: 92, sa: Self.flatLadder[2] + 1)
            #expect(Self.diagnostics(glyphs).count == 1)
        }

        /// The control, and the reason the report is scoped to blocks: a key
        /// the reader accepts whole says nothing, or a 657-score corpus would
        /// drown in it.
        @Test func aBlockThatMatchesSaysNothing() {
            #expect(Self.diagnostics(Self.flatBlock(3)).isEmpty)
        }

        /// The key ladder is anchored to the clef in force, and `runningClef`
        /// starts at G. So a staff whose clef never reaches the reader — the
        /// glyph detected but landing outside every measure's x range, which
        /// is what a raster front-end does — is silently read as treble, and
        /// its whole key block then sits two steps off the ladder it is
        /// compared with. Measured on this corpus: a bass staff's flats came
        /// out at `seen [2,5]` against `ladder [4,7]`, which is EXACTLY the F
        /// ladder, while the census showed all 26 of that document's bass
        /// clefs detected. Nothing said so.
        @Test func aStaffWhoseClefNeverArrivesSaysSoRatherThanAssumingTreble() {
            let events = Self.diagnostics([
                Self.glyph(.noteheadBlack, x: 80, sa: 4),
            ])
            #expect(events.count == 1)
            #expect(events.first?.message.contains("no clef") == true)
        }

        /// The control: a staff that declares its clef says nothing.
        @Test func aStaffThatDeclaresAClefIsSilent() {
            let events = Self.diagnostics([
                Self.glyph(.clefG, x: 60, sa: 4),
                Self.glyph(.noteheadBlack, x: 80, sa: 4),
            ])
            #expect(events.isEmpty)
        }

        /// An empty staff has nothing to misread, so it is not worth a line
        /// in a diagnostics log that a whole corpus flows through.
        @Test func aStaffWithNoContentAtAllIsSilent() {
            #expect(Self.diagnostics([]).isEmpty)
        }

        /// A lone leading accidental is a local accidental on the first note
        /// far more often than a one-flat key, and the reader already has a
        /// guard for that case. Reporting it would fire on ordinary music.
        @Test func aSingleLeadingAccidentalIsNotABlock() {
            let glyphs = [
                Self.glyph(.clefG, x: 60, sa: 4),
                Self.glyph(.accidentalFlat, x: 80, sa: Self.flatLadder[0] + 1),
                Self.glyph(.noteheadBlack, x: 86, sa: Self.flatLadder[0] + 1),
            ]
            #expect(Self.diagnostics(glyphs).isEmpty)
        }
    }
#endif
