#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    import SheetMusicLayoutApple
    @testable import SheetMusicPDF
    import Testing

    /// Stem attachment must be a function of the ENGRAVING, not of the page
    /// scale the score happens to be printed at.
    ///
    /// WHY THIS EXISTS. A notehead's own stem abuts its right edge (stem-up)
    /// or its left edge (stem-down), and that offset is a property of the
    /// music font, measured in staff spaces — so it grows with the staff.
    /// The importer instead matched a notehead to a stem within a FIXED ±7pt
    /// window. Measured over the 135-score real corpus, the legitimate
    /// offsets form two tight clusters at **0.0–0.1 sp** (stem-down) and
    /// **1.2–1.3 sp** (stem-up), with nothing legitimate beyond 1.5 sp; the
    /// staff space itself ranges over **2.4pt … 6.0pt**. A fixed 7pt window
    /// is therefore 1.4 sp only at the corpus's most common spatium (5.0pt)
    /// — it is 2.9 sp on the smallest staves (wide enough to grab a
    /// NEIGHBOUR's stem) and 1.18 sp on the largest (too narrow to reach the
    /// note's OWN stem).
    ///
    /// The measured failure: `疑事無功_piano` engraves at spatium 5.95pt, so
    /// every stem-up stem sits 7.41pt from its notehead origin — 0.41pt
    /// outside the window. 577 noteheads on that score found no stem at all,
    /// each becoming its own one-note chord, which read as "the treble
    /// chords fragment" (chords 318 → 451 with the note total unchanged).
    ///
    /// The invariant below is the scale-independence itself: the SAME
    /// engraving rendered at two staff sizes must import to the same chord.
    @MainActor struct PDFImporterStemWindowScaleTests {
        private nonisolated static var bravuraAvailable: Bool {
            guard #available(macOS 15.0, *) else { return false }
            return BravuraFont.register
        }

        private static let bravuraFontName = "Bravura"
        private static let noteX: CGFloat = 150

        /// Distance from a notehead's origin to its own stem-up stem, in
        /// staff spaces. Measured on `疑事無功_piano`: 7.41pt at a 5.95pt
        /// staff space, on 577 noteheads, to the pt.
        private static let stemOffsetInSpaces: CGFloat = 1.245

        /// One bar holding a single three-note chord under one stem, engraved
        /// at the given staff space. Everything scales together — glyph size,
        /// staff lines, stem offset — exactly as a real engraver's output
        /// does when the page scale changes.
        private static func fixture(lineGap: CGFloat) -> Data {
            let staffTop: CGFloat = 700
            let midLine = staffTop - 2 * lineGap
            let lines = (0 ..< 5).map {
                PDFFixtureBuilder.PathPlacement(
                    origin: CGPoint(x: 60, y: staffTop - CGFloat($0) * lineGap),
                    kind: .horizontal(width: 260),
                )
            }
            let clef = PDFFixtureBuilder.GlyphPlacement(
                unicodeScalar: "\u{E050}", fontName: bravuraFontName,
                fontSize: 4 * lineGap,
                origin: CGPoint(x: 66, y: staffTop - 3 * lineGap),
            )
            let ys = [midLine, midLine + lineGap, midLine + 2 * lineGap]
            let heads = ys.map {
                PDFFixtureBuilder.GlyphPlacement(
                    unicodeScalar: "\u{E0A4}", fontName: bravuraFontName,
                    fontSize: 4 * lineGap, origin: CGPoint(x: noteX, y: $0),
                )
            }
            let stem = PDFFixtureBuilder.PathPlacement(
                origin: CGPoint(
                    x: noteX + stemOffsetInSpaces * lineGap, y: ys[0],
                ),
                kind: .vertical(height: ys[2] - ys[0] + 3.6 * lineGap),
                lineWidth: 0.8,
            )
            return PDFFixtureBuilder.build(
                glyphs: [clef] + heads, paths: lines + [stem],
                dropToUnicodeCMaps: true,
            )
        }

        private static func chordSizes(_ score: Score) -> [Int] {
            var out: [Int] = []
            for part in score.parts {
                for staff in part.staves {
                    for measure in staff.measures {
                        for voice in measure.voices {
                            for element in voice.elements {
                                if case let .chord(chord) = element, !chord.notes.isEmpty {
                                    out.append(chord.notes.count)
                                }
                            }
                        }
                    }
                }
            }
            return out
        }

        /// THE INVARIANT. A three-note chord stays a three-note chord at every
        /// staff size a real score is engraved at. The corpus spans 2.4pt to
        /// 6.0pt; 5.95 is the size that broke, and 5.0 is the size the old
        /// fixed window was (accidentally) tuned for — it must not regress.
        @Test(.enabled(if: bravuraAvailable), arguments: [3.0, 4.0, 5.0, 5.95, 6.0] as [CGFloat])
        func aChordSurvivesEveryStaffSize(lineGap: CGFloat) throws {
            let score = try PDFImporter.parse(pdfData: Self.fixture(lineGap: lineGap))
            let sizes = Self.chordSizes(score)
            #expect(sizes.contains(3), "lineGap \(lineGap): chord sizes \(sizes)")
        }
    }
#endif
