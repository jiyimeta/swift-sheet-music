// Guarded because this reads the checkout through `#filePath`, the same reason `ShippedMetricsTableTests` is: a WASI
// test host has no preopened directory beyond the SwiftPM test bundle. The condition stands in for host-filesystem
// access. (The Windows checkout the release gate builds from carries no `Web/` or `Examples/` either; the Mac run is
// the one that guards these copies.)
#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    import Foundation
    import Testing

    /// One file `SheetMusicRenderWindows` bundles for Windows hosts and the file in this repository it is a copy of.
    struct WindowsBundledCopy: Sendable, CustomTestStringConvertible {
        /// The file's name in `Sources/SheetMusicRenderWindows/Resources`.
        var name: String
        /// Its source, relative to the repository root.
        var source: String

        var testDescription: String {
            name
        }

        static let folder = "Sources/SheetMusicRenderWindows/Resources"
        private static let appleFonts = "Sources/SheetMusicLayoutApple/Fonts/Resources"
        private static let exampleFonts = "Examples/Apple/SheetMusicExample/Resources/Fonts"

        /// Every bundled file but the folder's README.
        static let all: [WindowsBundledCopy] = [
            WindowsBundledCopy(name: "Bravura.otf", source: "\(appleFonts)/Bravura.otf"),
            WindowsBundledCopy(name: "Bravura.LICENSE.txt", source: "\(appleFonts)/Bravura.LICENSE.txt"),
            WindowsBundledCopy(name: "Edwin-Roman.otf", source: "\(exampleFonts)/Edwin-Roman.otf"),
            WindowsBundledCopy(name: "Edwin-Italic.otf", source: "\(exampleFonts)/Edwin-Italic.otf"),
            WindowsBundledCopy(name: "Edwin-Bold.otf", source: "\(exampleFonts)/Edwin-Bold.otf"),
            WindowsBundledCopy(name: "Edwin-BdIta.otf", source: "\(exampleFonts)/Edwin-BdIta.otf"),
            WindowsBundledCopy(name: "Edwin.LICENSE.txt", source: "\(exampleFonts)/LICENSE.txt"),
            WindowsBundledCopy(name: "sheet-music.smft", source: "Web/sheet-music-web/assets/sheet-music.smft"),
        ]
    }

    /// Pins the files `SheetMusicRenderWindows` bundles (`ScoreSurface.init()`, `installWindowsFontMetrics()`)
    /// byte-equal to their sources.
    ///
    /// The module is declared only on a Windows host, so no Mac build reads these copies, and the Windows gate is run
    /// by hand before a release. Without this suite a regenerated `sheet-music.smft` or an updated Bravura would leave
    /// Windows laying out with a table that no longer matches this revision's fonts or layout, and nothing would say
    /// so until a Windows page looked wrong.
    @Suite("Windows bundled resources")
    struct WindowsBundledResourcesTests {
        private static let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests/SheetMusicTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repository root

        private static func url(_ relativePath: String) -> URL {
            repositoryRoot.appendingPathComponent(relativePath)
        }

        @Test("each bundled file is a byte-for-byte copy of its source", arguments: WindowsBundledCopy.all)
        func copyMatchesSource(_ copy: WindowsBundledCopy) throws {
            let bundled = try Data(contentsOf: Self.url("\(WindowsBundledCopy.folder)/\(copy.name)"))
            let source = try Data(contentsOf: Self.url(copy.source))
            // Not vacuous: two empty files would compare equal.
            #expect(!source.isEmpty, "\(copy.source) is empty")
            #expect(
                bundled == source,
                "\(copy.name) differs from \(copy.source): copy the source into \(WindowsBundledCopy.folder)",
            )
        }

        /// A file added to the folder without a row above would ship unpinned; one whose row was dropped would too.
        @Test("every file in the bundled folder is pinned, and every pinned file is there")
        func folderHoldsExactlyThePinnedFiles() throws {
            let listed = try FileManager.default.contentsOfDirectory(atPath: Self.url(WindowsBundledCopy.folder).path)
            let shipped = Set(listed.filter { !$0.hasPrefix(".") && $0 != "README.md" })
            #expect(shipped == Set(WindowsBundledCopy.all.map(\.name)))
        }
    }
#endif
