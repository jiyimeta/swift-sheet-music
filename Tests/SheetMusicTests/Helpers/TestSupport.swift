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
/// it installs the same `bravura.smft` table the browser ships, via
/// `makeSMuFLMetricsTableProvider(table:)`
/// (`Sources/SheetMusicBridgeCore/SMuFLMetricsTable.swift`).
/// `Tools/GenWebFixtures/main.swift`'s `installSharedMetrics` does the
/// equivalent install for the fixture generator.
///
/// The two providers agree on every Bravura assertion in this suite, exact
/// Y-positions of ascent/descent-centred glyphs included: the table carries
/// Bravura's own ascent and descent since SMFT v3, and
/// `LayoutElementShapeTests` / `SkylineAutoplaceTests` run on every shape
/// through `installFontMetrics` to prove it. What they still disagree on is
/// TEXT: the table measures Bravura alone, so Edwin's ascent and descent
/// come from the stub, and the two assertions in those files that pin an
/// Edwin-derived Y stay behind `SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT`
/// for that reason. Both installers are
/// `static let`s, so each runs its closure at most once per process, the
/// same idempotence `SheetMusicLayoutApple.install` and the plain
/// `FontMetrics.provider` static var already rely on elsewhere.
enum TestSupport {
    #if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
        /// Test-suite-side eager installer for the Apple FontMetricsProvider.
        /// Reference `_ = TestSupport.installApple` from any suite that hits
        /// `LayoutEngine.layout(...)` directly (not through UI/PDF).
        /// The static-let chains into `SheetMusicLayoutApple.install`, which
        /// is itself a static-let and so this whole thing is process-wide
        /// idempotent.
        static let installApple: Bool = {
            if #available(macOS 15.0, *) {
                _ = SheetMusicLayoutApple.install
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

    #if !SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
        /// Installs the portable `bravura.smft` table provider in place of
        /// CoreText. Loaded through `TestResources` rather than `#filePath`
        /// or an absolute path, because WASI has no preopened directory
        /// beyond the test bundle.
        private static func installTable() {
            guard
                let url = TestResources.url(forResource: "bravura", withExtension: "smft")
            else {
                fatalError("bravura.smft test fixture not found via TestResources")
            }
            do {
                let table = try SMuFLMetricsTable.decode(Data(contentsOf: url))
                FontMetrics.provider = makeSMuFLMetricsTableProvider(table: table)
            } catch {
                fatalError("could not decode bravura.smft: \(error)")
            }
        }
    #endif
}
