import Foundation
import SheetMusicLayout
import SheetMusicLayoutApple

/// Bundles + registers the Edwin OFL font family on app launch.
/// MuseScore's `Sid::*FontFace` defaults all reference "Edwin", and
/// `SheetMusicLayout` resolves text faces via SwiftUI's named-font
/// path — so registering Edwin here lets dynamics, rehearsal marks,
/// staff text and lyrics render with the same typography MuseScore
/// uses. Skipping this step makes everything fall back to the
/// platform system font.
enum EdwinFontLoader {
    /// Idempotent — safe to call from multiple lifecycle hooks.
    static func registerOnce() {
        guard Bundle.main.url(
            forResource: "Edwin-Roman",
            withExtension: "otf",
            subdirectory: "Fonts",
        ) != nil else {
            return
        }
        let urls = [
            "Edwin-Roman", "Edwin-Bold",
            "Edwin-Italic", "Edwin-BdIta",
        ].compactMap {
            Bundle.main.url(
                forResource: $0,
                withExtension: "otf",
                subdirectory: "Fonts",
            )
        }
        SheetMusicFonts.register(urls: urls)
    }
}
