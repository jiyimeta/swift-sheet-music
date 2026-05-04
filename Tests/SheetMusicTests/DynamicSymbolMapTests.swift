@testable import SheetMusicUI
import Testing

@Suite struct DynamicSymbolMapTests {
    @Test func mapsSingleLetterDynamics() {
        #expect(DynamicSymbolMap.glyphs(for: "p") == ["\u{E520}"])
        #expect(DynamicSymbolMap.glyphs(for: "f") == ["\u{E522}"])
        #expect(DynamicSymbolMap.glyphs(for: "m") == ["\u{E521}"])
    }

    @Test func composesMultiLetterDynamics() {
        #expect(DynamicSymbolMap.glyphs(for: "mp") == [
            "\u{E521}", "\u{E520}", // mezzo + piano
        ])
        #expect(DynamicSymbolMap.glyphs(for: "mf") == [
            "\u{E521}", "\u{E522}", // mezzo + forte
        ])
        #expect(DynamicSymbolMap.glyphs(for: "fff") == [
            "\u{E522}", "\u{E522}", "\u{E522}",
        ])
        #expect(DynamicSymbolMap.glyphs(for: "sf") == [
            "\u{E524}", "\u{E522}", // sforzando + forte
        ])
        #expect(DynamicSymbolMap.glyphs(for: "fp") == [
            "\u{E522}", "\u{E520}", // forte + piano
        ])
    }

    @Test func caseInsensitive() {
        #expect(DynamicSymbolMap.glyphs(for: "FF") == [
            "\u{E522}", "\u{E522}",
        ])
        #expect(DynamicSymbolMap.glyphs(for: "Mp") == [
            "\u{E521}", "\u{E520}",
        ])
    }

    @Test func freeFormTextFallsThrough() {
        // "cresc.", "espressivo", "subito p" etc. shouldn't be
        // shoehorned into glyphs — the renderer falls back to
        // Edwin italic 10pt when this returns nil.
        #expect(DynamicSymbolMap.glyphs(for: "cresc.") == nil)
        #expect(DynamicSymbolMap.glyphs(for: "espressivo") == nil)
        #expect(DynamicSymbolMap.glyphs(for: "subito p") == nil)
        #expect(DynamicSymbolMap.glyphs(for: "") == nil)
        #expect(DynamicSymbolMap.glyphs(for: "   ") == nil)
    }
}
