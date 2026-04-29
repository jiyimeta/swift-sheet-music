#if os(macOS)
import CoreText
@testable import SheetMusicLayout
@testable import SheetMusicUI
import Testing

@Suite("Bravura font registration")
struct BravuraFontTests {
    @Test("Bravura is registered and resolvable by CoreText")
    func bravuraIsResolvable() {
        guard #available(macOS 15.0, *) else {
            return
        }
        let ok = BravuraFont.register
        #expect(ok, "BravuraFont.register returned false — the font was not installed")
        let font = CTFontCreateWithName(
            "Bravura" as CFString, 12, nil
        )
        let resolvedFamily = CTFontCopyFamilyName(font) as String
        #expect(resolvedFamily == "Bravura",
                "CoreText resolved '\(resolvedFamily)' instead of 'Bravura' — glyphs will render as tofu")
    }
}
#endif
