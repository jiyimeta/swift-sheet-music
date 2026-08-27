#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    import SheetMusicLayoutApple
    @testable import SheetMusicPDF
    import Testing

    /// A flag makes its note an eighth at every staff size, and it does so
    /// whether the note stands alone or sits in a chord.
    ///
    /// WHERE A FLAG ACTUALLY IS. It attaches at the stem's BARE end — the end
    /// away from the noteheads. Measured over the 135-score real corpus, of
    /// the ~54,000 flag glyphs sharing a stem's x column, 53,058 sit within
    /// **0.04 staff spaces of that end** (both orientations), and the next
    /// population is 3.1 sp away — a different note's flag in the same
    /// column. The stem end is therefore the invariant, and it is exact.
    ///
    /// `applyFlags` instead measured from the LEAD NOTEHEAD, through a fixed
    /// `4 ... 22` pt window. That is wrong twice:
    ///
    ///   * it is a fixed number of points for a distance that scales with the
    ///     staff — an engraving-correct 3.5 sp stem is 28pt at an 8pt staff
    ///     space, outside the window, so the eighth silently read as a
    ///     QUARTER (`PDFSyntheticTupletTests` documents having to shrink its
    ///     fixture's staff to dodge exactly this);
    ///   * and the lead notehead is not where the flag is. On a chord the
    ///     stem end is a chord-height farther away, which is why the corpus
    ///     shows legitimate notehead-to-flag distances spread over 1.1 … 4.5
    ///     sp with a tail past 5 sp instead of one tight cluster.
    struct PDFImporterFlagAttachTests {
        private nonisolated static var bravuraAvailable: Bool {
            guard #available(macOS 15.0, *) else { return false }
            return BravuraFont.register
        }

        private static let bravuraFontName = "Bravura"
        private static let noteX: CGFloat = 150

        /// Engraved stem length for a flagged note, in staff spaces — the
        /// corpus's dominant value (40,563 of ~54,000 flags).
        private static let stemLengthInSpaces: CGFloat = 3.5

        /// One bar with a single flagged eighth, engraved at `lineGap`.
        /// `extraHeads` stacks additional chord tones BELOW the flagged note,
        /// which moves the stem's bare end farther from the lead head without
        /// moving the flag.
        private static func fixture(
            lineGap: CGFloat, extraHeads: Int = 0,
        ) -> Data {
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
            // Chord tones a third apart, the flagged one on top.
            let ys = (0 ... extraHeads).map {
                midLine - CGFloat(extraHeads - $0) * lineGap
            }
            let heads = ys.map {
                PDFFixtureBuilder.GlyphPlacement(
                    unicodeScalar: "\u{E0A4}", fontName: bravuraFontName,
                    fontSize: 4 * lineGap, origin: CGPoint(x: noteX, y: $0),
                )
            }
            // Stem-up: from the LOWEST head to 3.5 sp above the highest.
            let stemX = noteX + 1.245 * lineGap
            let stemBottom = ys[0]
            let stemTop = ys[ys.count - 1] + stemLengthInSpaces * lineGap
            let stem = PDFFixtureBuilder.PathPlacement(
                origin: CGPoint(x: stemX, y: stemBottom),
                kind: .vertical(height: stemTop - stemBottom), lineWidth: 0.8,
            )
            let flag = PDFFixtureBuilder.GlyphPlacement(
                unicodeScalar: "\u{E240}", // flag8thUp
                fontName: bravuraFontName, fontSize: 4 * lineGap,
                origin: CGPoint(x: stemX, y: stemTop),
            )
            return PDFFixtureBuilder.build(
                glyphs: [clef] + heads + [flag], paths: lines + [stem],
                dropToUnicodeCMaps: true,
            )
        }

        private static func durations(_ score: Score) -> [NoteDuration] {
            var out: [NoteDuration] = []
            for part in score.parts {
                for staff in part.staves {
                    for measure in staff.measures {
                        for voice in measure.voices {
                            for element in voice.elements {
                                if case let .chord(chord) = element, !chord.notes.isEmpty {
                                    out.append(chord.duration)
                                }
                            }
                        }
                    }
                }
            }
            return out
        }

        /// THE INVARIANT: the staff size must not change the note's value.
        /// The corpus spans 2.4pt … 6.0pt staff spaces; 5.0 is the size the
        /// old fixed window was tuned at and 8.0 is the size
        /// `PDFSyntheticTupletTests` had to avoid.
        @Test(
            .enabled(if: bravuraAvailable),
            arguments: [3.0, 5.0, 6.0, 8.0] as [CGFloat],
        )
        func aFlaggedNoteIsAnEighthAtEveryStaffSize(lineGap: CGFloat) throws {
            let score = try PDFImporter.parse(pdfData: Self.fixture(lineGap: lineGap))
            #expect(
                Self.durations(score).contains(.eighth),
                "lineGap \(lineGap): \(Self.durations(score))",
            )
        }

        /// And the flag still reaches its note when the chord below it pushes
        /// the stem's bare end away from the lead notehead — the case a
        /// notehead-anchored window cannot express.
        @Test(.enabled(if: bravuraAvailable), arguments: [1, 2, 3])
        func aFlaggedChordIsAnEighthHoweverTallItIs(extraHeads: Int) throws {
            let score = try PDFImporter.parse(
                pdfData: Self.fixture(lineGap: 5, extraHeads: extraHeads),
            )
            #expect(
                Self.durations(score).contains(.eighth),
                "extraHeads \(extraHeads): \(Self.durations(score))",
            )
        }

        /// One bar with a single flagged note whose FLAG GLYPH is anchored
        /// `flagOffsetInSpaces` back along the stem from its bare end, which
        /// is what a multi-hook flag really does — the glyph has to reach
        /// down the stem to hang its hooks.
        private static func offsetFlagFixture(
            flagScalar: Unicode.Scalar,
            flagOffsetInSpaces: CGFloat,
            flagXOffsetInSpaces: CGFloat = 0,
            lineGap: CGFloat = 5,
        ) -> Data {
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
            let head = PDFFixtureBuilder.GlyphPlacement(
                unicodeScalar: "\u{E0A4}", fontName: bravuraFontName,
                fontSize: 4 * lineGap, origin: CGPoint(x: noteX, y: midLine),
            )
            let stemX = noteX + 1.245 * lineGap
            let stemTop = midLine + stemLengthInSpaces * lineGap
            let stem = PDFFixtureBuilder.PathPlacement(
                origin: CGPoint(x: stemX, y: midLine),
                kind: .vertical(height: stemTop - midLine), lineWidth: 0.8,
            )
            let flag = PDFFixtureBuilder.GlyphPlacement(
                unicodeScalar: flagScalar,
                fontName: bravuraFontName, fontSize: 4 * lineGap,
                origin: CGPoint(
                    x: stemX + flagXOffsetInSpaces * lineGap,
                    y: stemTop - flagOffsetInSpaces * lineGap,
                ),
            )
            return PDFFixtureBuilder.build(
                glyphs: [clef, head, flag], paths: lines + [stem],
                dropToUnicodeCMaps: true,
            )
        }

        /// A 64th flag's glyph origin sits about a staff space back along
        /// the stem, not at its bare end — measured at 0.94–1.17 sp on
        /// `cov_flags` and `extz_Now_is_the_time` (16ths reach 0.47).
        /// Against the old single 0.5 sp tolerance EVERY 64th flag was
        /// rejected and its note fell back to a bare QUARTER: 192 of that
        /// fixture's 352 notes, with the other 160 (32nds, offset 0.20)
        /// correct — a duration score of 45% whose cause was a gate, not a
        /// recognition failure.
        @Test(
            .enabled(if: bravuraAvailable),
            arguments: [0.0, 0.5, 1.0, 1.2] as [CGFloat],
        )
        func aFlagAnchoredBackAlongTheStemStillReachesItsNote(
            offsetInSpaces: CGFloat,
        ) throws {
            let score = try PDFImporter.parse(pdfData: Self.offsetFlagFixture(
                flagScalar: "\u{E246}", // flag64thUp
                flagOffsetInSpaces: offsetInSpaces,
            ))
            #expect(
                Self.durations(score).contains(.sixtyFourth),
                "offset \(offsetInSpaces) sp: \(Self.durations(score))",
            )
        }

        /// The Y bound is not "however far away": beyond it lies the next
        /// population, another note's flag in the same column, measured at
        /// 3.1 sp. A gate that admitted that would trade dropped flags for
        /// stolen ones.
        @Test(.enabled(if: bravuraAvailable))
        func aFlagFarBeyondTheStemEndIsNotThisNotesFlag() throws {
            let score = try PDFImporter.parse(pdfData: Self.offsetFlagFixture(
                flagScalar: "\u{E246}",
                flagOffsetInSpaces: 3.1,
            ))
            #expect(
                !Self.durations(score).contains(.sixtyFourth),
                "a flag 3.1 sp off the stem end was claimed: \(Self.durations(score))",
            )
        }

        /// And X keeps the TIGHTER bound, which is the whole reason the two
        /// are separate constants. In x a note's own flag sits within 0.1 sp
        /// and the nearest neighbour's is 1.1 sp away, so widening x the way
        /// y was widened would re-introduce the flag theft the x-gate exists
        /// to stop.
        @Test(.enabled(if: bravuraAvailable))
        func aFlagInTheNextNotesColumnIsNotClaimed() throws {
            let score = try PDFImporter.parse(pdfData: Self.offsetFlagFixture(
                flagScalar: "\u{E246}",
                flagOffsetInSpaces: 1.0,
                flagXOffsetInSpaces: 1.1,
            ))
            #expect(
                !Self.durations(score).contains(.sixtyFourth),
                "a flag 1.1 sp away in x was claimed: \(Self.durations(score))",
            )
        }
    }
#endif
