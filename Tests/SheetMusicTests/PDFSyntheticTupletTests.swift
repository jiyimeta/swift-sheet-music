#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    import SheetMusic
    @testable import SheetMusicCore
    import SheetMusicLayoutApple
    @testable import SheetMusicPDF
    import Testing

    /// End-to-end gate for tuplet-mark recognition, on a fixture engraved in
    /// memory so it runs on CI where the copyrighted corpus is absent.
    ///
    /// One 4/4 bar on one staff: a beamed sixteenth triplet under a "3", then
    /// a quarter and an eighth under a bracket with a "3" in the bracket's
    /// gap, then a half note. Read straight the bar is 3/16 + 1/4 + 1/8 + 1/2
    /// = 17/16; read correctly it is 1/8 + 1/4 + 1/2 = exactly one bar, so a
    /// correct read needs no help from `reconcileMeasureDurations` and a
    /// wrong one cannot be rescued into the same answer.
    ///
    /// The value of driving `PDFImporter.parse` over real CoreGraphics-written
    /// bytes — rather than hand-built `TextGlyph`s — is that it is the only
    /// shape that catches a PRODUCTION-ONLY assumption. Twice in this feature
    /// a wall of green unit tests missed one: `TextGlyph.bbox` is `.zero` in
    /// production while every fixture set it by hand, and the CMap show loop
    /// recorded a run's origin one advance too far right while every fixture
    /// assumed the pen position. Both are load-bearing here — `digitExtent`
    /// reads `origin.x` and `renderedSize`, never `bbox` — so this file would
    /// have gone red on either.
    @MainActor struct PDFSyntheticTupletTests {
        /// The fixture draws its noteheads with the bundled Bravura, which
        /// reaches CoreText through `BravuraFont` and so needs macOS 15 while
        /// this package deploys to macOS 14. CI runs macOS 15.
        ///
        /// `nonisolated` (rather than inheriting the enclosing type's
        /// `@MainActor`) so it can be read from a `.enabled(if:)` trait,
        /// which is evaluated outside the struct's isolation. Feeding it to
        /// `.enabled(if:)` — instead of a `guard ... else { return }` at the
        /// top of every test — makes a macOS 14 host report these as
        /// explicitly SKIPPED rather than silently PASSED with zero
        /// assertions run.
        private nonisolated static var bravuraAvailable: Bool {
            guard #available(macOS 15.0, *) else { return false }
            return BravuraFont.register
        }

        private static let bravuraFontName = "Bravura"

        // Staff geometry. `lineGap` 5pt puts the spatium in the same range as
        // the real corpus (4-5pt), which matters because several downstream
        // thresholds are absolute points rather than spatia — most sharply
        // `applyFlags`' 4...22pt notehead-to-flag window. At lineGap 8 the
        // engraving-correct 3.5-spatium stem puts the flag 28pt up, outside
        // that window, and the eighth silently reads as a quarter.
        private static let staffTop: CGFloat = 700
        private static let lineGap: CGFloat = 5
        private static let midLine = staffTop - 2 * lineGap // 690
        /// Stem tip, 3.6 spatia above the notehead — normal engraved length.
        private static let stemTop = midLine + 18 // 708
        /// Baseline of a tuplet number. Inside `tupletMarkBandSpatia` (3sp)
        /// above the top staff line, and within `tupletBracketDigitYTolSpatia`
        /// (1.5sp) of the bracket arms.
        private static let markY = staffTop + 11 // 711
        private static let bracketArmY = staffTop + 14 // 714
        /// The beams rise 1.5pt across their span. NOT cosmetic: CoreGraphics'
        /// PDF writer collapses a FLAT four-corner fill back into one `re … f`
        /// operator, which the walker captures as `.rectangle` with no quad —
        /// so a level beam here would never reach the `.beam` branch the
        /// detector keys on. A sloped parallelogram cannot be written as `re`
        /// and survives as `m l l l h f`. Measured: with slope 0 the walker
        /// reported 0 beams and 2 rectangles.
        private static let beamSlope: CGFloat = 1.5
        /// Distance from a notehead's origin to its own stem. Inside
        /// `nearestStem`'s window (1.4 × this fixture's 5pt staff space) and
        /// right of the origin, so `stemLegalityLeftSlop` is satisfied and
        /// the stem reads as stem-up.
        private static let stemOffset: CGFloat = 5.5

        private static func staffLines() -> [PDFFixtureBuilder.PathPlacement] {
            (0 ..< 5).map {
                PDFFixtureBuilder.PathPlacement(
                    origin: CGPoint(x: 60, y: staffTop - CGFloat($0) * lineGap),
                    kind: .horizontal(width: 260),
                )
            }
        }

        private static func notehead(
            _ scalar: UnicodeScalar, x: CGFloat,
        ) -> PDFFixtureBuilder.GlyphPlacement {
            PDFFixtureBuilder.GlyphPlacement(
                unicodeScalar: scalar, fontName: bravuraFontName,
                fontSize: 4 * lineGap, origin: CGPoint(x: x, y: midLine),
            )
        }

        private static func stem(noteX: CGFloat) -> PDFFixtureBuilder.PathPlacement {
            PDFFixtureBuilder.PathPlacement(
                origin: CGPoint(x: noteX + stemOffset, y: midLine),
                kind: .vertical(height: stemTop - midLine), lineWidth: 0.8,
            )
        }

        /// A tuplet number, as ordinary Latin text. CoreGraphics embeds a CJK
        /// face as Type0/Identity-H with no `/ToUnicode`, which the importer
        /// cannot decode at all, so every text glyph here stays Latin.
        private static func tupletDigit(
            x: CGFloat, y: CGFloat = markY,
        ) -> PDFFixtureBuilder.GlyphPlacement {
            PDFFixtureBuilder.GlyphPlacement(
                unicodeScalar: "3", fontName: "Helvetica",
                fontSize: 6, origin: CGPoint(x: x, y: y),
            )
        }

        /// A beamed sixteenth triplet at x 120/140/160, its two beam lines
        /// spanning the three stems, and its "3" centred over them.
        private static func beamedTriplet(
            glyphs: inout [PDFFixtureBuilder.GlyphPlacement],
            paths: inout [PDFFixtureBuilder.PathPlacement],
        ) {
            for i in 0 ..< 3 {
                let x = 120 + CGFloat(i) * 20
                glyphs.append(notehead("\u{E0A4}", x: x)) // noteheadBlack
                paths.append(stem(noteX: x))
            }
            for top in [stemTop, stemTop - 3.5] {
                paths.append(PDFFixtureBuilder.PathPlacement(
                    origin: CGPoint(x: 124, y: top - 2.5),
                    kind: .beam(width: 43, thickness: 2.5, slope: beamSlope),
                ))
            }
            glyphs.append(tupletDigit(x: 144))
        }

        /// A quarter at x 200 and a flagged eighth at x 230 under a bracket
        /// whose two arms leave a gap for the "3". This is the path a beam
        /// cannot cover — a triplet quarter + eighth is unbeamable, so
        /// MuseScore always brackets it.
        private static func bracketedPair(
            glyphs: inout [PDFFixtureBuilder.GlyphPlacement],
            paths: inout [PDFFixtureBuilder.PathPlacement],
        ) {
            for x in [CGFloat(200), CGFloat(230)] {
                glyphs.append(notehead("\u{E0A4}", x: x))
                paths.append(stem(noteX: x))
            }
            glyphs.append(PDFFixtureBuilder.GlyphPlacement(
                unicodeScalar: "\u{E240}", // flag8thUp
                fontName: bravuraFontName, fontSize: 4 * lineGap,
                origin: CGPoint(x: 230 + stemOffset, y: stemTop),
            ))
            paths.append(PDFFixtureBuilder.PathPlacement(
                origin: CGPoint(x: 204, y: bracketArmY), kind: .horizontal(width: 14),
            ))
            paths.append(PDFFixtureBuilder.PathPlacement(
                origin: CGPoint(x: 226, y: bracketArmY), kind: .horizontal(width: 12),
            ))
            for x in [CGFloat(204), CGFloat(238)] {
                paths.append(PDFFixtureBuilder.PathPlacement(
                    origin: CGPoint(x: x, y: stemTop),
                    kind: .vertical(height: bracketArmY - stemTop),
                ))
            }
            glyphs.append(tupletDigit(x: 220))
        }

        private static func fixture() -> Data {
            var paths = staffLines()
            var glyphs = [PDFFixtureBuilder.GlyphPlacement(
                unicodeScalar: "\u{E050}", // gClef
                fontName: bravuraFontName, fontSize: 4 * lineGap,
                origin: CGPoint(x: 66, y: staffTop - 3 * lineGap),
            )]
            beamedTriplet(glyphs: &glyphs, paths: &paths)
            bracketedPair(glyphs: &glyphs, paths: &paths)
            glyphs.append(notehead("\u{E0A3}", x: 280)) // noteheadHalf
            paths.append(stem(noteX: 280))
            return PDFFixtureBuilder.build(
                glyphs: glyphs, paths: paths, dropToUnicodeCMaps: true,
            )
        }

        // MARK: - Stem-down variant, for the lyric-collision case

        /// Stem tip of a stem-DOWN note, and the beam / number below it.
        /// Mirrors the geometry above through the staff.
        private static let stemBottom = midLine - 16 // 674
        private static let markBelowY = staffTop - 33 // 667
        private static let lyricY = staffTop - 50 // 650

        /// A stem-DOWN stem. It stands at the notehead's LEFT edge — i.e. at
        /// the origin itself — which is why `windowIndices` grants a
        /// stem-down note no slack: its `RhythmElement.x` already IS its stem.
        private static func stemDown(noteX: CGFloat) -> PDFFixtureBuilder.PathPlacement {
            PDFFixtureBuilder.PathPlacement(
                origin: CGPoint(x: noteX, y: stemBottom),
                kind: .vertical(height: midLine - stemBottom), lineWidth: 0.8,
            )
        }

        /// A stem-DOWN eighth triplet whose beam and "3" hang BELOW the staff,
        /// plus a sung syllable under every note.
        ///
        /// This is the arrangement that makes the lyric exclusion load-bearing:
        /// `filterLyricCandidates` only looks in a band BELOW the bottom staff
        /// line (`lyricBandDepthSpatia` = 8sp), so a number engraved ABOVE the
        /// staff — as in `fixture()` — could never have become a syllable in
        /// the first place. Here the "3" sits 13pt under the staff, squarely
        /// inside that band and in the same x cell as the notes, so the only
        /// thing keeping it out of the lyrics is `detectTupletMarks` having
        /// claimed it.
        ///
        /// Straight the bar reads 3/8 + 1/2 + 1/4 = 9/8; with the triplet
        /// recognized it is 1/4 + 1/2 + 1/4 = exactly one bar.
        private static func lyricBandFixture() -> Data {
            var paths = staffLines()
            var glyphs = [PDFFixtureBuilder.GlyphPlacement(
                unicodeScalar: "\u{E050}", // gClef
                fontName: bravuraFontName, fontSize: 4 * lineGap,
                origin: CGPoint(x: 66, y: staffTop - 3 * lineGap),
            )]
            for x in [CGFloat(120), 140, 160, 200, 240] {
                glyphs.append(notehead(x == 200 ? "\u{E0A3}" : "\u{E0A4}", x: x))
                paths.append(stemDown(noteX: x))
                glyphs.append(PDFFixtureBuilder.GlyphPlacement(
                    unicodeScalar: "a", fontName: "Helvetica",
                    fontSize: 6, origin: CGPoint(x: x, y: lyricY),
                ))
            }
            // One beam line only, so the three notes read as eighths.
            paths.append(PDFFixtureBuilder.PathPlacement(
                origin: CGPoint(x: 118, y: stemBottom - 2.5),
                kind: .beam(width: 45, thickness: 2.5, slope: beamSlope),
            ))
            glyphs.append(tupletDigit(x: 138, y: markBelowY))
            return PDFFixtureBuilder.build(
                glyphs: glyphs, paths: paths, dropToUnicodeCMaps: true,
            )
        }

        private static func parse(_ data: Data, named name: String) throws -> Score {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(name)
            try data.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            return try PDFImporter.parse(pdfURL: url)
        }

        private static func chords(of score: Score) -> [Chord] {
            score.parts.flatMap(\.staves).flatMap(\.measures)
                .flatMap(\.voices).flatMap(\.elements)
                .compactMap { element -> Chord? in
                    if case let .chord(chord) = element, !chord.notes.isEmpty {
                        return chord
                    }
                    return nil
                }
        }

        private static func fraction(_ n: Int, _ d: Int) -> NoteDuration {
            .fraction(Fraction(numerator: n, denominator: d))
        }

        /// The fixture is itself a gate. If CoreGraphics ever stops writing the
        /// beam quad as `m l l l h f`, or stops embedding the music face as a
        /// simple font with `uniXXXX` `/Differences` names, the assertions
        /// below would go vacuously true (no notes at all trivially has no
        /// wrong durations). Pin the walker's view so that shows up as a
        /// broken fixture rather than as a passing gate.
        ///
        /// `renderedSize` is pinned deliberately: it is the ONLY size
        /// `digitExtent` can use. `fontSize` here is 1.0 — CoreGraphics emits
        /// `Tf 1` and carries the real scale in the text matrix — so a
        /// `fontSize`-derived digit width would be 6x too narrow.
        @Test(.enabled(if: Self.bravuraAvailable))
        func fixtureEngravesWhatTheDetectorNeeds() throws {
            let walked = try PDFImporter.ContentStreamWalker(
                document: PDFImporter.openDocument(Self.fixture()),
            ).walk()
            #expect(walked.paths.count(where: { $0.kind == .beam }) == 2)
            #expect(walked.glyphs.count(where: { $0.semantic == .noteheadBlack }) == 5)
            #expect(walked.glyphs.contains { $0.semantic == .flag8thUp })
            let digits = walked.texts.filter { $0.text == "3" }
            #expect(digits.count == 2)
            #expect(digits.allSatisfy { $0.renderedSize == 6 })
            // `TextGlyph.bbox` is never populated by the content-stream
            // walker in production (it always comes back `.zero`); fixing
            // that is deliberately deferred to its own branch. Assert the
            // POST-FIX shape (a populated bbox) rather than today's `.zero`,
            // wrapped in `withKnownIssue`: `withKnownIssue` treats the body
            // NOT recording an issue as itself a failure, so asserting
            // today's `.zero` value directly would fail immediately (the
            // body never records an issue because it's already true) rather
            // than staying green until the fix lands. With the assertion
            // inverted, today it fails inside the block (bbox IS `.zero`,
            // not populated) — caught and reported as a known issue, test
            // green — and the day `bbox` is populated, the block stops
            // failing, `withKnownIssue` reports "Known issue was not
            // recorded", and that self-explanatory message is what reads as
            // the known issue being resolved, rather than an ordinary
            // opaque `#expect` regression.
            withKnownIssue("TextGlyph.bbox is not populated by the content-stream walker yet") {
                #expect(digits.allSatisfy { $0.bbox != .zero })
            }
        }

        /// Both marks come back with their true tuplet durations: three
        /// sixteenth-triplet notes at 1/24 from the BEAM anchor, and a
        /// quarter + eighth at 1/6 and 1/12 from the BRACKET anchor.
        @Test(.enabled(if: Self.bravuraAvailable))
        func bothTupletsRecoverTheirTrueDurations() throws {
            let score = try Self.parse(Self.fixture(), named: "synthetic-tuplet.pdf")
            let durations = Self.chords(of: score).map(\.duration)
            #expect(durations.count(where: { $0 == Self.fraction(1, 24) }) == 3)
            #expect(durations.contains(Self.fraction(1, 6)))
            #expect(durations.contains(Self.fraction(1, 12)))
            #expect(durations.contains(.half))
        }

        /// Every scaled member sits inside a `Tuplet` span.
        ///
        /// Baking the ratio into the duration and stopping there leaves the score unexportable: the MSCX encoder
        /// un-scales a member through its enclosing tuplet, and one with no tuplet around it is written as
        /// `<durationType>measure</durationType>`, which the Chord decoder refuses. Covered end-to-end by
        /// `anImportedTupletSurvivesAnMSCZRoundTrip`; asserted structurally here so a regression names its cause.
        @Test(.enabled(if: Self.bravuraAvailable))
        func everyScaledMemberIsInsideATuplet() throws {
            let score = try Self.parse(Self.fixture(), named: "synthetic-tuplet-spans.pdf")
            var scaledMembers = 0
            for voice in score.parts.flatMap(\.staves).flatMap(\.measures).flatMap(\.voices) {
                for (index, element) in voice.elements.enumerated() {
                    guard case let .chord(chord) = element,
                          case .fraction = chord.duration
                    else { continue }
                    scaledMembers += 1
                    #expect(voice.tuplets.contains { $0.startIndex <= index && index <= $0.endIndex })
                }
            }
            #expect(scaledMembers > 0)
        }

        /// The defect this file grew for: a PDF with a triplet exported to `.mscz` could not be read back, so any app
        /// that converts an imported PDF into a score wrote a file it could never reopen.
        @Test(.enabled(if: Self.bravuraAvailable))
        func anImportedTupletSurvivesAnMSCZRoundTrip() throws {
            let score = try Self.parse(Self.fixture(), named: "synthetic-tuplet-roundtrip.pdf")
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("synthetic-tuplet-roundtrip.mscz")
            defer { try? FileManager.default.removeItem(at: url) }

            try SheetMusic.exportMSCZ(score, to: url)
            let reloaded = try SheetMusic.loadScore(msczData: Data(contentsOf: url))

            let durations = Self.chords(of: reloaded).map(\.duration)
            #expect(durations.count(where: { $0 == Self.fraction(1, 24) }) == 3)
        }

        /// The bracket path in particular: a triplet quarter + eighth cannot be
        /// beamed, so the bracket is the only anchor available and
        /// `applyTupletMarks` must treat its span as authoritative.
        @Test(.enabled(if: Self.bravuraAvailable))
        func theBracketedPairIsScaledFromItsBracket() throws {
            let score = try Self.parse(
                Self.fixture(), named: "synthetic-tuplet-bracket.pdf",
            )
            let durations = Self.chords(of: score).map(\.duration)
            #expect(!durations.contains(.quarter))
            #expect(!durations.contains(.eighth))
        }

        /// A tuplet number claimed by `detectTupletMarks` is excluded from
        /// `attachLyrics`, so no chord ends up singing "3" — asserted on the
        /// stem-DOWN fixture, where the number really does fall in the lyric
        /// band next to five real syllables. The syllable count is asserted
        /// alongside so a fixture that stopped producing lyrics at all could
        /// not pass this as an absence.
        @Test(.enabled(if: Self.bravuraAvailable))
        func theTupletNumberInTheLyricBandIsNotSung() throws {
            let score = try Self.parse(
                Self.lyricBandFixture(), named: "synthetic-tuplet-lyrics.pdf",
            )
            let chords = Self.chords(of: score)
            let lyrics = chords.flatMap(\.lyrics)
            #expect(lyrics.count(where: { $0.text == "a" }) == 5)
            #expect(!lyrics.contains { $0.text == "3" })
            // The digit is absent from the lyrics BECAUSE the tuplet pass
            // claimed it — so pin that it was in fact claimed and applied.
            #expect(
                chords.map(\.duration)
                    .count(where: { $0 == Self.fraction(1, 12) }) == 3,
            )
        }
    }
#endif
