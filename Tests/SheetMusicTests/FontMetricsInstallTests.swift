import SheetMusicLayout
import Testing

/// Proves `TestSupport.installFontMetrics` actually put a real provider in
/// force, rather than inferring it from other tests passing.
///
/// `LayoutEngine.layout`'s own DEBUG assert that a real provider is
/// installed is guarded `#if DEBUG && canImport(CoreText)`
/// (`Sources/SheetMusicLayout/Layout/LayoutEngine.swift:55`), so on
/// Android/WebAssembly a missing or mis-wired install fails silently:
/// layout keeps running against `StubFontMetricsProvider`'s rectangle
/// approximations instead of crashing loudly the way it does on Apple.
/// A green run is exactly what that failure mode produces.
@Suite("TestSupport.installFontMetrics")
struct FontMetricsInstallTests {
    private let _installFontMetrics = TestSupport.installFontMetrics

    #if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
        @Test("installs a real provider, not the stub, on Apple")
        func installsRealProviderOnApple() {
            #expect(!(FontMetrics.provider is StubFontMetricsProvider))
        }
    #else
        /// On Android and WebAssembly, `installFontMetrics` installs the
        /// portable `bravura.smft` table, never CoreText and never left as
        /// the default stub. The table provider's `ascent`/`descent`
        /// unconditionally delegate to `StubFontMetricsProvider`'s formula
        /// (`Sources/SheetMusicBridgeCore/SMuFLMetricsTable.swift`), so
        /// that signal alone can't tell it apart from a silent stub
        /// fallback — but `glyphPathBoundingBox` for a real Bravura glyph
        /// comes from measured table data and differs from the stub's
        /// placeholder rectangle. Both signals together positively
        /// identify the table provider rather than merely "not the stub".
        ///
        /// **The two `ascent`/`descent` assertions pin a KNOWN DEFECT, not
        /// intended behaviour.** `SMuFLMetricsTableProvider` delegates them to
        /// the stub for every face including Bravura, where CoreText reports a
        /// symmetric ascent ≈ descent ≈ 2.012em — so `(ascent - descent) / 2`,
        /// which several call sites use to centre a glyph, is 0 on Apple and
        /// 0.30 × pointSize elsewhere. When that is fixed, this test SHOULD
        /// fail. Update these two lines to the corrected values; do not delete
        /// them and do not loosen them, or the next regression in the same
        /// place goes unnoticed. `glyphPathBoundingBox` alone is enough to
        /// identify the provider, so nothing here depends on the defect
        /// surviving.
        @Test("installs the SMuFL metrics table, not the stub")
        func installsTheTableProvider() {
            let bravuraEm = LayoutFont(face: SMuFLFamily.bravura, pointSize: 4)
            let stub = StubFontMetricsProvider()
            let installed = FontMetrics.provider

            #expect(!(installed is StubFontMetricsProvider))
            #expect(installed.ascent(font: bravuraEm) == stub.ascent(font: bravuraEm))
            #expect(installed.descent(font: bravuraEm) == stub.descent(font: bravuraEm))

            let noteheadBlack: UInt16 = 0xE0A4
            let installedBox = installed.glyphPathBoundingBox(
                font: bravuraEm, codepoint: noteheadBlack,
            )
            let stubBox = stub.glyphPathBoundingBox(
                font: bravuraEm, codepoint: noteheadBlack,
            )
            #expect(installedBox != nil)
            #expect(installedBox != stubBox)
        }
    #endif
}
