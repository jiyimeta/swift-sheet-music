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
        /// portable `sheet-music.smft` table, never CoreText and never left as
        /// the default stub. Two signals identify it: `ascent`/`descent` for
        /// Bravura come from the table's own face record (SMFT v3) and differ
        /// from `StubFontMetricsProvider`'s 0.85 / 0.25 em formula, and
        /// `glyphPathBoundingBox` for a real Bravura glyph comes from measured
        /// table data and differs from the stub's placeholder rectangle.
        ///
        /// **The `ascent`/`descent` values are pinned exactly on purpose.**
        /// Bravura declares ascender 2012 and descender −2012 at 1000 upm —
        /// hhea, OS/2 typo and win metrics all agree — so at the pointSize-4
        /// "Bravura em" the table serves 8.048 for each, the same numbers
        /// CoreText reports on Apple. (CoreText's own reading is 2012.004 at
        /// the 1000 pt reference size, fixed-point noise the tolerance below
        /// absorbs.) `(ascent − descent) / 2` is what
        /// `ArticulationGlyphMetrics`, `FermataGlyphMetrics`,
        /// `BreathGlyphMetrics`, `ChordLineGeometry` and `LayoutElementShape`
        /// use to centre a glyph on its baseline; before v3 the provider fell
        /// back to the stub here and put those glyphs 1.2 sp off on both
        /// non-Apple platforms. Do not loosen these two lines to "not the
        /// stub": that is exactly the assertion which let the defect ship.
        @Test("installs the SMuFL metrics table, not the stub")
        func installsTheTableProvider() {
            let bravuraEm = LayoutFont(face: SMuFLFamily.bravura, pointSize: 4)
            let stub = StubFontMetricsProvider()
            let installed = FontMetrics.provider

            #expect(!(installed is StubFontMetricsProvider))
            #expect(abs(Double(installed.ascent(font: bravuraEm)) - 8.048) < 1e-3)
            #expect(abs(Double(installed.descent(font: bravuraEm)) - 8.048) < 1e-3)

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

        /// The same argument, one face down. SMFT v4 measures Edwin as well,
        /// and the way that fails silently is the table installing with only
        /// Bravura in it: text keeps answering from the stub, every lyric row
        /// sits ~1.4 pt off and every text width is a bucket average, and
        /// nothing errors.
        ///
        /// Pinned exactly, for the same reason the Bravura pair is. Edwin
        /// reports 0.737 / 0.263 / 0.200 em where the stub answers
        /// 0.85 / 0.25 / 0 — and it is the leading that no "not the stub"
        /// check would catch, since a table with no text face and a table
        /// whose text face lost its line gap both answer 0.
        @Test("installs the text face too, line gap included")
        func installsTheTextFace() {
            let edwin = LayoutFont(face: "Edwin", pointSize: 100)
            let installed = FontMetrics.provider
            #expect(abs(Double(installed.ascent(font: edwin)) - 73.7) < 0.1)
            #expect(abs(Double(installed.descent(font: edwin)) - 26.3) < 0.1)
            #expect(abs(Double(installed.leading(font: edwin)) - 20.0) < 0.1)
            // "Ill" is where the stub's buckets are worst: 0.65 / 0.5 / 0.5 em
            // against three of Edwin's narrowest letters.
            let stub = StubFontMetricsProvider()
            let measured = installed.typographicWidth(text: "Ill", font: edwin)
            #expect(abs(Double(measured - stub.typographicWidth(text: "Ill", font: edwin))) > 10)
        }
    #endif
}
