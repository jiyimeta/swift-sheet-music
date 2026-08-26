#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import Foundation
    @testable import SheetMusicCore
    import SheetMusicLayoutApple
    @testable import SheetMusicPDF
    import Testing

    /// The music-font gate's regression tests, on a SYNTHETIC fixture.
    ///
    /// `PDFImporterShapeMatchingGateTests` asserts the same three behaviors,
    /// but only when `~/Desktop/pdf_test/ギブス.pdf` is present — a
    /// copyrighted file that cannot be committed. On CI that file is absent
    /// and all three tests `return` before asserting anything, so the
    /// "automated gate" the Task-12/14 ledger refers to does not actually
    /// run anywhere except one developer's machine. This file is that gate.
    ///
    /// It builds its own engraved staff in memory — five staff lines, a G
    /// clef, eight stemmed noteheads, a lyric syllable under each — so it
    /// runs everywhere the bundled Bravura face is available, and keeps the
    /// corpus-backed tests as the higher-fidelity local check rather than
    /// replacing them.
    @MainActor struct PDFSyntheticShapeMatchingGateTests {
        /// Tier 4 can only answer where the bundled Bravura exemplars built,
        /// and those reach the face through `BravuraFont`, which needs macOS
        /// 15 while this package deploys to macOS 14. The same fixture also
        /// needs that face to DRAW its noteheads, so on such a host there is
        /// nothing to assert either way. CI runs macOS 15.
        private static var bravuraAvailable: Bool {
            guard #available(macOS 15.0, *) else { return false }
            return BravuraFont.register && !BravuraExemplars.all.isEmpty
        }

        /// Five staff lines, a G clef, eight stemmed black noteheads, and a
        /// Latin lyric syllable under each notehead.
        ///
        /// The lyric face is Latin rather than CJK on purpose: CoreGraphics
        /// embeds a CJK face as Type0/Identity-H with NO `/ToUnicode`, which
        /// the importer cannot decode at all, so those draws disappear
        /// before any tier sees them (measured: 8 CJK draws, 0 text runs).
        /// A Latin face is embedded as a simple font and comes through as
        /// real text that `buildScore` turns into `Lyric`s.
        private static func engravedStaff() -> Data {
            let staffTop: CGFloat = 700
            let lineGap: CGFloat = 8
            var paths = (0 ..< 5).map {
                PDFFixtureBuilder.PathPlacement(
                    origin: CGPoint(x: 60, y: staffTop - CGFloat($0) * lineGap),
                    kind: .horizontal(width: 460),
                )
            }
            var glyphs: [PDFFixtureBuilder.GlyphPlacement] = [
                PDFFixtureBuilder.GlyphPlacement(
                    unicodeScalar: "\u{E050}", // gClef
                    fontName: BravuraFontName, fontSize: 4 * lineGap,
                    origin: CGPoint(x: 66, y: staffTop - 3 * lineGap),
                ),
            ]
            for i in 0 ..< noteCount {
                let x = 90 + CGFloat(i) * 50
                glyphs.append(PDFFixtureBuilder.GlyphPlacement(
                    unicodeScalar: "\u{E0A4}", // noteheadBlack
                    fontName: BravuraFontName, fontSize: 4 * lineGap,
                    origin: CGPoint(x: x, y: staffTop - 2 * lineGap),
                ))
                paths.append(PDFFixtureBuilder.PathPlacement(
                    origin: CGPoint(x: x + 5.5, y: staffTop - 2 * lineGap),
                    kind: .vertical(height: 3 * lineGap), lineWidth: 1.0,
                ))
                glyphs.append(PDFFixtureBuilder.GlyphPlacement(
                    unicodeScalar: "a", fontName: "Helvetica",
                    fontSize: 9, origin: CGPoint(x: x, y: staffTop - 8 * lineGap),
                ))
            }
            return PDFFixtureBuilder.build(
                glyphs: glyphs, paths: paths, dropToUnicodeCMaps: true,
            )
        }

        private static let noteCount = 8
        private static let BravuraFontName = "Bravura"

        private static func lyricCount(of score: Score) -> Int {
            score.parts.flatMap(\.staves).flatMap(\.measures)
                .flatMap(\.voices).flatMap(\.elements)
                .compactMap { element -> Chord? in
                    if case let .chord(chord) = element { return chord }
                    return nil
                }
                .reduce(0) { $0 + $1.lyrics.count }
        }

        /// The fixture itself is a gate: if CoreGraphics ever stops
        /// embedding the music face as a simple font with `uniXXXX`
        /// `/Differences` names, every assertion below would go vacuously
        /// true (no notes at all trivially loses no lyrics). Pin the shape
        /// of the fixture so that failure is reported as a broken fixture
        /// rather than as passing gates.
        @Test func fixtureProducesAClassifiedStaffWithLyrics() throws {
            guard Self.bravuraAvailable else { return }
            let data = Self.engravedStaff()

            let walked = try PDFImporter.ContentStreamWalker(
                document: PDFImporter.openDocument(data),
            ).walk()
            let noteheads = walked.glyphs.filter { $0.semantic == .noteheadBlack }
            #expect(noteheads.count == Self.noteCount)
            #expect(walked.glyphs.contains { $0.semantic == .clefG })
            #expect(walked.texts.count == Self.noteCount)

            let score = try PDFImporter.parse(pdfData: data)
            #expect(score.totalStaffCount == 1)
            #expect(Self.lyricCount(of: score) == Self.noteCount)
        }

        /// Turning `enableShapeMatching` ON must not cost a single lyric:
        /// the per-font gate (`GlyphClassifier.isLikelyMusicFont`) has to
        /// keep Tier 4 away from the text face's outlines.
        ///
        /// This is the assertion that a regression in the gate — or in the
        /// threading of the flag from `PDFImportOptions` through
        /// `walkDocument` to each `GlyphClassifier` — would break.
        @Test func shapeMatchingWithGateKeepsEveryLyric() throws {
            guard Self.bravuraAvailable else { return }
            var options = PDFImportOptions()
            options.enableShapeMatching = true
            let score = try PDFImporter.parse(pdfData: Self.engravedStaff(), options: options)
            #expect(Self.lyricCount(of: score) == Self.noteCount)
        }

        /// Proves the test above is a genuine catch rather than a tautology.
        ///
        /// With the gate forced open (`musicFontGateFraction = 0` accepts
        /// every font regardless of its sampled distances) and
        /// `shapeAcceptanceThreshold` restored to the pre-Task-14
        /// placeholder (0.45), Tier 4 matches the TEXT face's outlines to
        /// Bravura exemplars, swallows the text runs `buildScore` would
        /// have turned into lyrics, and the count collapses to zero — the
        /// same failure Task 12 measured on a real PDF (lyric recall 92% →
        /// 0%), reproduced here with no corpus.
        @Test func noGateAtPlaceholderThresholdCollapsesLyrics() throws {
            guard Self.bravuraAvailable else { return }
            var options = PDFImportOptions()
            options.enableShapeMatching = true
            options.musicFontGateFraction = 0
            options.musicFontGateBound = 1.0
            options.shapeAcceptanceThreshold = 0.45
            let score = try PDFImporter.parse(pdfData: Self.engravedStaff(), options: options)
            #expect(Self.lyricCount(of: score) == 0)
        }
    }
#endif
