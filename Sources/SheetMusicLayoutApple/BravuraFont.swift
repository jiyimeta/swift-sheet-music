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

        guard let url = SheetMusicFonts.bravuraURL else {
            logger.error("Bravura.otf not found in any known bundle")
            return false
        }
        return registerFont(at: url, logger: logger)
    }()

    /// Registers the font at `url` for the process. `true` when CoreText now has it — registered here, or already
    /// registered before (kCTFontManagerErrorAlreadyRegistered, 105: a host such as `SheetMusicFonts.register(urls:)`
    /// may have installed the same file first).
    ///
    /// The error CoreText hands back is +1: it is taken retained exactly once, and its code read from that reference.
    /// Reading it again unretained after the retained take could read a released object: it crashed a release-built
    /// host (folino's video probe, 2026-11-16), though in this package's tests CoreText kept the error alive.
    static func registerFont(at url: URL, logger: Logger) -> Bool {
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            logger.info("Bravura registered from \(url.path, privacy: .public)")
            return true
        }
        let failure = error?.takeRetainedValue()
        if let failure, CFErrorGetCode(failure) == 105 {
            logger.info("Bravura already registered (reused)")
            return true
        }
        let desc = failure?.localizedDescription ?? "unknown CTFontManager error"
        logger.error("CTFontManagerRegisterFontsForURL failed: \(desc, privacy: .public)")
        return false
    }
}
