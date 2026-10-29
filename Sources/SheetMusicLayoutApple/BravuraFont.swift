import CoreText
import Foundation
import os

/// Runtime registration of the bundled Bravura SMuFL font.
///
/// Registration is process-scoped — it does not affect system font caches
/// outside the host application.
///
/// The font is `SheetMusicFonts.bravuraURL`, located through `BundledResource`'s
/// cascade of bundles so it works in SwiftPM, in an Xcode-built host app and
/// in the Xcode Preview runner alike.
///
/// When CoreText resolves "Bravura" to the fallback system font (because
/// registration silently failed), SwiftUI displays tofu boxes in place of
/// SMuFL glyphs. The diagnostics below help pinpoint where that happened.
@available(macOS 15.0, *)
public enum BravuraFont {
    /// Registration result, published the first time `register` is touched.
    /// `true` means CoreText can now resolve the Bravura family in this
    /// process. `false` means all resolution strategies failed; glyphs
    /// will render as tofu until the caller supplies the font another way.
    public static let register: Bool = {
        let logger = Logger(
            subsystem: "swift-sheet-music.SheetMusicLayoutApple",
            category: "BravuraFont",
        )

        if let url = SheetMusicFonts.bravuraURL {
            var error: Unmanaged<CFError>?
            let ok = CTFontManagerRegisterFontsForURL(
                url as CFURL, .process, &error,
            )
            if ok {
                logger.info("Bravura registered from \(url.path, privacy: .public)")
                return true
            }
            let desc = error?.takeRetainedValue().localizedDescription
                ?? "unknown CTFontManager error"
            // kCTFontManagerErrorAlreadyRegistered (105) is harmless — it
            // means a previous register call (e.g. in the same process)
            // already installed the font.
            if let cfErr = error?.takeUnretainedValue(),
               CFErrorGetCode(cfErr) == 105
            {
                logger.info("Bravura already registered (reused)")
                return true
            }
            logger.error("CTFontManagerRegisterFontsForURL failed: \(desc, privacy: .public)")
        } else {
            logger.error("Bravura.otf not found in any known bundle")
        }
        return false
    }()
}
