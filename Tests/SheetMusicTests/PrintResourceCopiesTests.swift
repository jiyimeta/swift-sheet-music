// Guarded like `WindowsBundledResourcesTests`: it reads the checkout through `#filePath`, which a WASI test host
// cannot, and the Android checkout the AAR is built from is this one — the Mac run is the one that guards the copies.
#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    import SheetMusicBridgeCore
    import SheetMusicLayoutApple
    import Testing

    /// One copy of a print resource that a platform ships, and the file in this repository it is a copy of.
    struct PrintResourceCopy: Sendable, CustomTestStringConvertible {
        /// The copy, relative to the repository root.
        var path: String
        /// Its source, relative to the repository root.
        var source: String

        var testDescription: String {
            path
        }

        /// The Android AAR's `assets/fonts/`.
        static let androidFolder = "Android/SheetMusicComposeAndroid/src/main/assets/fonts"
        /// `SheetMusicLayoutApple`'s resources, which `.process("Fonts/Resources")` puts in its bundle.
        static let appleFolder = "Sources/SheetMusicLayoutApple/Fonts/Resources"
        /// The Windows table: its bold and italic records measure the styled faces below, which is what the PDF
        /// writer embeds.
        static let styledTable = "Sources/SheetMusicRenderWindows/Resources/sheet-music.smft"
        private static let exampleFonts = "Examples/Apple/SheetMusicExample/Resources/Fonts"

        static let all: [PrintResourceCopy] = [
            PrintResourceCopy(path: "\(androidFolder)/Edwin-Italic.otf", source: "\(exampleFonts)/Edwin-Italic.otf"),
            PrintResourceCopy(path: "\(androidFolder)/Edwin-Bold.otf", source: "\(exampleFonts)/Edwin-Bold.otf"),
            PrintResourceCopy(path: "\(androidFolder)/Edwin-BdIta.otf", source: "\(exampleFonts)/Edwin-BdIta.otf"),
            PrintResourceCopy(path: "\(androidFolder)/sheet-music-styled.smft", source: styledTable),
            // `SheetMusicFonts.portableMetricsTableURL`: a video lays its text out with this table on Apple too, so
            // its picture is Android's.
            PrintResourceCopy(path: "\(appleFolder)/sheet-music-styled.smft", source: styledTable),
        ]
    }

    /// Pins the print resources each platform ships byte-equal to their sources. Android prints through `ScorePages`
    /// and `ScorePDFWriter` with these bytes, and a video lays out with the same table on Apple and Android, so a
    /// regenerated table or an updated Edwin that did not reach a copy would lay out with metrics that no longer match
    /// the faces drawn — and nothing on that platform would say so until text overran its frame, or the two platforms'
    /// pictures differed.
    @Suite("Print resource copies")
    struct PrintResourceCopiesTests {
        private static let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/SheetMusicTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root

        private static func url(_ relativePath: String) -> URL {
            repositoryRoot.appendingPathComponent(relativePath)
        }

        @Test("each print resource is a byte-for-byte copy of its source", arguments: PrintResourceCopy.all)
        func copyMatchesSource(_ copy: PrintResourceCopy) throws {
            let shipped = try Data(contentsOf: Self.url(copy.path))
            let source = try Data(contentsOf: Self.url(copy.source))
            // Not vacuous: two empty files would compare equal.
            #expect(!source.isEmpty, "\(copy.source) is empty")
            #expect(shipped == source, "\(copy.path) differs from \(copy.source): copy the source over it")
        }

        /// The copy above is what the Apple module serves: the resource rule carries it into the bundle unchanged, and
        /// the bundle lookup finds it there.
        @available(macOS 15.0, *)
        @Test("the Apple module's bundle serves its copy of the styled table, and the copy decodes")
        func theAppleBundleServesTheStyledTable() throws {
            let url = try #require(SheetMusicFonts.portableMetricsTableURL)
            let bundled = try Data(contentsOf: url)
            let source = try Data(contentsOf: Self.url(PrintResourceCopy.styledTable))
            #expect(!source.isEmpty, "\(PrintResourceCopy.styledTable) is empty")
            #expect(bundled == source, "\(url.path) is not \(PrintResourceCopy.styledTable)")
            _ = try makeFontMetricsTableProvider(table: FontMetricsTable.decode(bundled))
        }
    }
#endif
