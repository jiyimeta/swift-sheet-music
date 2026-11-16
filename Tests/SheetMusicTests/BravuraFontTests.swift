#if os(macOS)
    import CoreText
    import Foundation
    import os
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

        /// A host that registers Bravura itself before `register` is first touched (folino's video export does, through
        /// `SheetMusicFonts.register(urls:)`) gets kCTFontManagerErrorAlreadyRegistered back: that answer counts as
        /// registered, and reading it must not touch a released error (it crashed in `objc_retain`, 2026-11-16).
        ///
        /// This pins the outcome, not the ownership: here CoreText keeps the error alive, so the old double read passes
        /// too, under Address Sanitizer included (checked 2026-11-16 with the old code put back).
        @available(macOS 15.0, *)
        @Test("registering Bravura when it is already registered reports it registered, without crashing")
        func alreadyRegisteredIsRegistered() throws {
            let url = try #require(SheetMusicFonts.bravuraURL)
            let logger = Logger(subsystem: "swift-sheet-music.tests", category: "BravuraFontTests")
            #expect(BravuraFont.registerFont(at: url, logger: logger))
            // Registered by now, by the call above or an earlier one in this process: this one gets 105.
            for _ in 0 ..< 3 {
                #expect(BravuraFont.registerFont(at: url, logger: logger))
            }
            #expect(SheetMusicFonts.register(urls: [url]) == [url])
            #expect(BravuraFont.registerFont(at: url, logger: logger))
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
