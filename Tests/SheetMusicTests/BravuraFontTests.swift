#if os(macOS)
    import CoreText
    import Foundation
    @testable import SheetMusicLayout
    @testable import SheetMusicLayoutApple
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
                "Bravura" as CFString, 12, nil,
            )
            let resolvedFamily = CTFontCopyFamilyName(font) as String
            #expect(
                resolvedFamily == "Bravura",
                "CoreText resolved '\(resolvedFamily)' instead of 'Bravura' — glyphs will render as tofu",
            )
        }

        /// The file `register` registers, handed to a host for the bytes a Swift-written PDF embeds as its music face.
        @available(macOS 15.0, *)
        @Test("the bundle lookup finds the Bravura file")
        func theBundleFindsBravura() throws {
            let url = try #require(SheetMusicFonts.bravuraURL)
            #expect(url.lastPathComponent == "Bravura.otf")
            #expect(try !Data(contentsOf: url).isEmpty)
        }
    }
#endif
