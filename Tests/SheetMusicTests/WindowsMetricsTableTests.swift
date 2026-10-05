// Guarded like `ShippedMetricsTableTests`: it reads the checkout through `#filePath` and measures with CoreText.
#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import CoreGraphics
    import CoreText
    import Foundation
    @testable import SheetMusicBridgeCore
    import Testing

    /// Pins the table `SheetMusicRenderWindows` bundles (`installWindowsFontMetrics()`), which
    /// `Tools/GenFontMetrics --family-styles` writes: the web table's Bravura and regular Edwin, and Edwin's styled
    /// records measured from the family's own files — the faces the Windows renderer draws (`DrawCommandWalker`) and
    /// the PDF writer embeds — rather than the regular outlines the browser strokes and shears.
    ///
    /// The fonts are read straight from their files here, never registered: registering Edwin's bold face would change
    /// what `CTFontCreateCopyWithSymbolicTraits` answers for every other suite in the process.
    @Suite("Windows metrics table")
    struct WindowsMetricsTableTests {
        private static let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/SheetMusicTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root

        private static let windowsTable = "Sources/SheetMusicRenderWindows/Resources/sheet-music.smft"
        private static let webTable = "Web/sheet-music-web/assets/sheet-music.smft"
        private static let fonts = "Sources/SheetMusicRenderWindows/Resources"

        /// A capital, a descender, a digit, a space and the widest Latin letter: the shapes a bold title, an italic
        /// expression and a lyric are spaced from.
        private static let sampled: [UInt32] = [0x0041, 0x0067, 0x0031, 0x0020, 0x0057]

        private static func table(_ relativePath: String) throws -> FontMetricsTable {
            try FontMetricsTable.decode(Data(contentsOf: repositoryRoot.appendingPathComponent(relativePath)))
        }

        private static func font(_ file: String) throws -> CTFont {
            let url = repositoryRoot.appendingPathComponent("\(fonts)/\(file)")
            let provider = try #require(CGDataProvider(url: url as CFURL))
            let graphics = try #require(CGFont(provider))
            return CTFontCreateWithGraphicsFont(graphics, 1000, nil, nil)
        }

        @Test("Bravura and regular Edwin are the web table's, entry for entry")
        func regularRecordsAreTheWebTables() throws {
            let windows = try Self.table(Self.windowsTable)
            let web = try Self.table(Self.webTable)
            #expect(windows.referenceSize == web.referenceSize)
            for name in ["Bravura", "Edwin"] {
                let ours = try #require(windows.face(named: name))
                let theirs = try #require(web.face(named: name))
                #expect([ours.ascent, ours.descent, ours.leading] == [theirs.ascent, theirs.descent, theirs.leading])
                // Not vacuous: two empty records would compare equal.
                #expect(theirs.entries.count > 500)
                #expect(Set(ours.entries.keys) == Set(theirs.entries.keys))
                for (codepoint, entry) in theirs.entries {
                    let mine = try #require(ours.entries[codepoint])
                    #expect(
                        [mine.advance, mine.bboxX, mine.bboxY, mine.bboxW, mine.bboxH]
                            == [entry.advance, entry.bboxX, entry.bboxY, entry.bboxW, entry.bboxH],
                        "\(name) U+\(String(codepoint, radix: 16, uppercase: true))",
                    )
                }
            }
        }

        @Test(
            "each styled record measures its own file",
            arguments: [
                ("Edwin-Bold", "Edwin-Bold.otf"),
                ("Edwin-Italic", "Edwin-Italic.otf"),
                ("Edwin-BoldItalic", "Edwin-BdIta.otf"),
            ],
        )
        func styledRecordMeasuresItsFile(record: String, file: String) throws {
            let face = try #require(Self.table(Self.windowsTable).face(named: record))
            let font = try Self.font(file)
            #expect(abs(face.ascent - Double(CTFontGetAscent(font))) < 0.5)
            #expect(abs(face.descent - Double(CTFontGetDescent(font))) < 0.5)
            #expect(abs(face.leading - Double(CTFontGetLeading(font))) < 0.5)
            for codepoint in Self.sampled {
                let entry = try #require(face.entries[codepoint], "\(record) lacks U+\(codepoint)")
                var character = UniChar(codepoint)
                var glyph: CGGlyph = 0
                try #require(CTFontGetGlyphsForCharacters(font, &character, &glyph, 1))
                var advance = CGSize.zero
                CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
                #expect(abs(entry.advance - Double(advance.width)) < 0.5, "\(record) U+\(codepoint)")
                guard let path = CTFontCreatePathForGlyph(font, glyph, nil), !path.isEmpty else {
                    #expect(entry.bboxW == 0 && entry.bboxH == 0, "\(record) U+\(codepoint) is blank")
                    continue
                }
                let box = path.boundingBoxOfPath
                #expect(abs(entry.bboxX - Double(box.minX)) < 0.5, "\(record) U+\(codepoint)")
                #expect(abs(entry.bboxW - Double(box.width)) < 0.5, "\(record) U+\(codepoint)")
                #expect(abs(entry.bboxH - Double(box.height)) < 0.5, "\(record) U+\(codepoint)")
            }
        }

        /// What the regenerated table is for: the web's styled records keep the regular advances (the browser strokes
        /// the regular outlines), which Windows, drawing Edwin's own bold, cannot use.
        @Test("the styled advances are the styled faces', not the regular face's")
        func styledAdvancesAreNotTheRegularOnes() throws {
            let windows = try Self.table(Self.windowsTable)
            let web = try Self.table(Self.webTable)
            let capitalA: UInt32 = 0x0041
            let regular = try #require(windows.face(named: "Edwin")?.entries[capitalA]?.advance)
            #expect(try #require(web.face(named: "Edwin-Bold")?.entries[capitalA]?.advance) == regular)
            #expect(try #require(windows.face(named: "Edwin-Bold")?.entries[capitalA]?.advance) != regular)
            #expect(try #require(windows.face(named: "Edwin-Italic")?.entries[capitalA]?.advance) != regular)
        }
    }
#endif
