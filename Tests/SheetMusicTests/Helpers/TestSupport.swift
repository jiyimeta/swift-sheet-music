import Foundation
import SheetMusicBridgeCore
import SheetMusicLayout
#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    @testable import SheetMusicLayoutApple
#endif

/// Test-suite-side eager installers for `FontMetrics.provider`.
///
/// `installApple` installs the real CoreText-backed provider — the one the
/// shipping app actually uses on Apple platforms — and only exists there.
/// `installFontMetrics` is the portable entry point: on Apple it defers to
/// `installApple`; everywhere CoreText doesn't exist (Android, WebAssembly)
/// it installs the same `sheet-music.smft` table the browser ships, via
/// `makeFontMetricsTableProvider(table:)`
/// (`Sources/SheetMusicBridgeCore/FontMetricsTable.swift`).
/// `Tools/GenWebFixtures/main.swift`'s `installSharedMetrics` does the
/// equivalent install for the fixture generator.
///
/// The two providers agree on every assertion in this suite, exact
/// Y-positions of ascent/descent-centred glyphs included: the table carries
/// Bravura's own ascent and descent since SMFT v3 and Edwin's ascent, descent
/// and line gap since v4, and `LayoutElementShapeTests` /
/// `SkylineAutoplaceTests` run on every shape through `installFontMetrics` to
/// prove it. Both installers are `static let`s, so each runs its closure at
/// most once per process, the same idempotence `SheetMusicLayoutApple.install`
/// and the plain `FontMetrics.provider` static var already rely on elsewhere.
enum TestSupport {
    #if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
        /// Test-suite-side eager installer for the Apple FontMetricsProvider.
        /// Reference `_ = TestSupport.installApple` from any suite that hits
        /// `LayoutEngine.layout(...)` directly (not through UI/PDF).
        /// The static-let chains into `SheetMusicLayoutApple.install`, which
        /// is itself a static-let and so this whole thing is process-wide
        /// idempotent.
        ///
        /// It ALSO registers the repo's Edwin. The package bundles Bravura and
        /// registers it itself, but leaves text faces to the host — and
        /// `CTFontCreateWithName` answers an unregistered family with the
        /// system font rather than nil, so on a machine without Edwin
        /// installed (this repo's CI runners, and most dev machines) every
        /// `face: "Edwin"` measurement here would silently be about Helvetica:
        /// 0.770 / 0.230 em with no line gap, against Edwin's 0.737 / 0.263 /
        /// 0.200. That is not what the shipping browser and Android builds
        /// draw, both of which bundle Edwin, and it is not what
        /// `sheet-music.smft` measures — so an unregistered Edwin would put
        /// the two providers a point and a half apart on every text row and
        /// make the cross-platform Y assertions unpinnable. Registering it is
        /// also exactly what `SheetMusicFonts.register(urls:)` documents an
        /// Apple host should do, and what the example app does.
        static let installApple: Bool = {
            if #available(macOS 15.0, *) {
                _ = SheetMusicLayoutApple.install
                SheetMusicFonts.register(urls: [TestFonts.edwinRomanURL])
            }
            return true
        }()
    #endif

    /// Reference `_ = TestSupport.installFontMetrics` from any suite that
    /// hits `LayoutEngine.layout(...)` directly and is expected to run on
    /// every platform shape, not just Apple. See the enum doc for which
    /// provider this resolves to per shape.
    static let installFontMetrics: Bool = {
        #if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
            _ = installApple
        #else
            installTable()
        #endif
        return true
    }()

    #if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
        /// Font files the suite registers itself, resolved relative to this
        /// file so the lookup does not depend on the working directory a
        /// runner happens to use. Apple-only: the other shapes read the
        /// measured table out of the test bundle instead, and WASI has no
        /// preopened directory to reach the repo with.
        enum TestFonts {
            /// The same copy `Scripts/web-fonts.sh` turns into
            /// `edwin-roman.woff2` and `Tools/GenFontMetrics` measures, so the
            /// CoreText provider and the table describe one font file.
            static let edwinRomanURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // Tests/SheetMusicTests/Helpers
                .deletingLastPathComponent() // Tests/SheetMusicTests
                .deletingLastPathComponent() // Tests
                .deletingLastPathComponent() // repo root
                .appendingPathComponent(
                    "Android/SheetMusicComposeAndroid/src/main/assets/fonts/Edwin-Roman.otf",
                )
        }
    #endif

    #if !SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
        /// Installs the portable `sheet-music.smft` table provider in place of
        /// CoreText. Loaded through `TestResources` rather than `#filePath`
        /// or an absolute path, because WASI has no preopened directory
        /// beyond the test bundle.
        private static func installTable() {
            guard
                let url = TestResources.url(forResource: "sheet-music", withExtension: "smft")
            else {
                fatalError("sheet-music.smft test fixture not found via TestResources")
            }
            do {
                let table = try FontMetricsTable.decode(Data(contentsOf: url))
                FontMetrics.provider = makeFontMetricsTableProvider(table: table)
            } catch {
                fatalError("could not decode sheet-music.smft: \(error)")
            }
        }
    #endif
}
