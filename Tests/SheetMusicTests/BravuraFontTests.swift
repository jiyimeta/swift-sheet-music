#if os(macOS)
import CoreText
@testable import SheetMusicUI
import Testing

@Suite("Bravura font registration")
struct BravuraFontTests {
    @Test("Bravura is registered and resolvable by CoreText")
    func bravuraIsResolvable() {
        guard #available(macOS 15.0, *) else {
            return
        }
        _ = BravuraFont.register
        let font = CTFontCreateWithName(
            "Bravura" as CFString, 12, nil
        )
        let resolvedFamily = CTFontCopyFamilyName(font) as String
        #expect(resolvedFamily == "Bravura")
    }
}
#endif
