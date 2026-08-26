#if SHEET_MUSIC_HAS_APPLE_PLATFORM_TEST_SUPPORT
    @testable import SheetMusicLayout
    @testable import SheetMusicUI
    import Testing

    struct DynamicSymbolMapTests {
        @Test func mapsSingleLetterDynamics() {
            #expect(DynamicSymbolMap.codepoints(for: "p") == [0xE520])
            #expect(DynamicSymbolMap.codepoints(for: "f") == [0xE522])
            #expect(DynamicSymbolMap.codepoints(for: "m") == [0xE521])
        }

        @Test func composesMultiLetterDynamics() {
            #expect(DynamicSymbolMap.codepoints(for: "mp") == [
                0xE521, 0xE520, // mezzo + piano
            ])
            #expect(DynamicSymbolMap.codepoints(for: "mf") == [
                0xE521, 0xE522, // mezzo + forte
            ])
            #expect(DynamicSymbolMap.codepoints(for: "fff") == [
                0xE522, 0xE522, 0xE522,
            ])
            #expect(DynamicSymbolMap.codepoints(for: "sf") == [
                0xE524, 0xE522, // sforzando + forte
            ])
            #expect(DynamicSymbolMap.codepoints(for: "fp") == [
                0xE522, 0xE520, // forte + piano
            ])
        }

        @Test func caseInsensitive() {
            #expect(DynamicSymbolMap.codepoints(for: "FF") == [
                0xE522, 0xE522,
            ])
            #expect(DynamicSymbolMap.codepoints(for: "Mp") == [
                0xE521, 0xE520,
            ])
        }

        @Test func freeFormTextFallsThrough() {
            // "cresc.", "espressivo", "subito p" etc. shouldn't be
            // shoehorned into glyphs — the renderer falls back to
            // Edwin italic 10pt when this returns nil.
            #expect(DynamicSymbolMap.codepoints(for: "cresc.") == nil)
            #expect(DynamicSymbolMap.codepoints(for: "espressivo") == nil)
            #expect(DynamicSymbolMap.codepoints(for: "subito p") == nil)
            #expect(DynamicSymbolMap.codepoints(for: "") == nil)
            #expect(DynamicSymbolMap.codepoints(for: "   ") == nil)
        }
    }
#endif
