// Guarded like `WindowsBundledResourcesTests`: it reads the checkout through `#filePath`, which a WASI test host
// cannot, and the Android checkout the AAR is built from is this one — the Mac run is the one that guards the copies.
#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    import Testing

    /// One print resource the Android AAR ships in `assets/fonts/` and the file in this repository it is a copy of.
    struct AndroidPrintCopy: Sendable, CustomTestStringConvertible {
        /// The file's name in `Android/SheetMusicComposeAndroid/src/main/assets/fonts`.
        var name: String
        /// Its source, relative to the repository root.
        var source: String

        var testDescription: String {
            name
        }

        static let folder = "Android/SheetMusicComposeAndroid/src/main/assets/fonts"
        private static let exampleFonts = "Examples/Apple/SheetMusicExample/Resources/Fonts"

        static let all: [AndroidPrintCopy] = [
            AndroidPrintCopy(name: "Edwin-Italic.otf", source: "\(exampleFonts)/Edwin-Italic.otf"),
            AndroidPrintCopy(name: "Edwin-Bold.otf", source: "\(exampleFonts)/Edwin-Bold.otf"),
            AndroidPrintCopy(name: "Edwin-BdIta.otf", source: "\(exampleFonts)/Edwin-BdIta.otf"),
            // The Windows table: its bold and italic records measure the styled faces above, which is what the PDF
            // writer embeds.
            AndroidPrintCopy(
                name: "sheet-music-styled.smft", source: "Sources/SheetMusicRenderWindows/Resources/sheet-music.smft",
            ),
        ]
    }

    /// Pins the print resources the Android AAR ships byte-equal to their sources. Android prints through `ScorePages`
    /// and `ScorePDFWriter` with these bytes, so a regenerated table or an updated Edwin that did not reach the copies
    /// would lay out a print with metrics that no longer match the faces embedded in it — and nothing on Android would
    /// say so until a PDF's text overran its frame.
    @Suite("Android print resources")
    struct AndroidPrintResourcesTests {
        private static let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/SheetMusicTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root

        private static func url(_ relativePath: String) -> URL {
            repositoryRoot.appendingPathComponent(relativePath)
        }

        @Test("each print resource is a byte-for-byte copy of its source", arguments: AndroidPrintCopy.all)
        func copyMatchesSource(_ copy: AndroidPrintCopy) throws {
            let shipped = try Data(contentsOf: Self.url("\(AndroidPrintCopy.folder)/\(copy.name)"))
            let source = try Data(contentsOf: Self.url(copy.source))
            // Not vacuous: two empty files would compare equal.
            #expect(!source.isEmpty, "\(copy.source) is empty")
            #expect(
                shipped == source,
                "\(copy.name) differs from \(copy.source): copy the source into \(AndroidPrintCopy.folder)",
            )
        }
    }
#endif
