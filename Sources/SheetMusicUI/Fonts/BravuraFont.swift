import CoreText
import Foundation
import os

/// Runtime registration of the bundled Bravura SMuFL font.
///
/// Registration is process-scoped — it does not affect system font caches
/// outside the host application.
///
/// The font is located via a cascade of strategies so it works in all
/// three typical load contexts:
///   1. SwiftPM / `swift run` / `swift test` — uses `Bundle.module`.
///   2. Xcode-built host app consuming the SwiftPM library — finds the
///      embedded `SheetMusicUI_SheetMusicUI.bundle` inside the app.
///   3. Xcode Preview runner — scans every loaded Bundle for the font.
///
/// When CoreText resolves "Bravura" to the fallback system font (because
/// registration silently failed), SwiftUI displays tofu boxes in place of
/// SMuFL glyphs. The diagnostics below help pinpoint where that happened.
@available(macOS 15.0, iOS 16.0, *)
public enum BravuraFont {
    public static let familyName = "Bravura"

    /// Registration result, published the first time `register` is touched.
    /// `true` means CoreText can now resolve the Bravura family in this
    /// process. `false` means all resolution strategies failed; glyphs
    /// will render as tofu until the caller supplies the font another way.
    public static let register: Bool = {
        let logger = Logger(
            subsystem: "swift-sheet-music.SheetMusicUI",
            category: "BravuraFont")

        if let url = locateBravuraURL(logger: logger) {
            var error: Unmanaged<CFError>?
            let ok = CTFontManagerRegisterFontsForURL(
                url as CFURL, .process, &error)
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
               CFErrorGetCode(cfErr) == 105 {
                logger.info("Bravura already registered (reused)")
                return true
            }
            logger.error("CTFontManagerRegisterFontsForURL failed: \(desc, privacy: .public)")
        } else {
            logger.error("Bravura.otf not found in any known bundle")
        }
        return false
    }()

    /// Walk every bundle strategy until Bravura.otf is located.
    ///
    /// The `.copy("Fonts/Resources")` resource rule in Package.swift
    /// preserves the last path component as a subdirectory inside the
    /// bundle — so in Xcode-built host apps the font ends up at
    /// `bundle/Contents/Resources/Resources/Bravura.otf`. Plain
    /// `url(forResource:withExtension:)` only scans the resource root,
    /// hence the explicit `subdirectory: "Resources"` fallback.
    private static func locateBravuraURL(logger: Logger) -> URL? {
        let candidates: [Bundle] = [
            Bundle.module,
            Bundle(for: BundleAnchor.self),
        ] + Bundle.allBundles + Bundle.allFrameworks

        for bundle in candidates {
            if let url = find(in: bundle) { return url }
            // Host apps may also embed the SheetMusicUI resource bundle
            // as a sibling .bundle; open it explicitly and search inside.
            if let nestedURL = bundle.url(
                    forResource: "swift-sheet-music_SheetMusicUI",
                    withExtension: "bundle"),
               let nested = Bundle(url: nestedURL),
               let url = find(in: nested) {
                return url
            }
        }
        logger.debug("Bravura.otf not located via any bundle strategy")
        return nil
    }

    private static func find(in bundle: Bundle) -> URL? {
        if let url = bundle.url(
            forResource: "Bravura", withExtension: "otf") {
            return url
        }
        if let url = bundle.url(
            forResource: "Bravura", withExtension: "otf",
            subdirectory: "Resources") {
            return url
        }
        return nil
    }
}

/// Private anchor used by `Bundle(for:)` to locate the binary that
/// contains the SheetMusicUI code (and, by convention, its resource
/// bundle). Not exposed — existence is an implementation detail.
@available(macOS 15.0, iOS 16.0, *)
private final class BundleAnchor {}
