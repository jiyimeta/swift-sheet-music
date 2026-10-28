import Foundation

/// Finds a file this module bundles (`Fonts/Resources`), wherever the host's build put the module's resource bundle.
///
/// The bundles are searched as a cascade, so a lookup works in the three typical load contexts:
///   1. SwiftPM / `swift run` / `swift test` — `Bundle.module`.
///   2. An Xcode-built host app consuming the SwiftPM library — the embedded
///      `swift-sheet-music_SheetMusicLayoutApple.bundle` inside the app.
///   3. The Xcode Preview runner — every loaded bundle and framework.
///
/// `.process("Fonts/Resources")` (Package.swift) puts the files at the resource bundle's root, while a `.copy` rule
/// keeps the last path component as a subdirectory (`…/Resources/Resources/<file>` in an Xcode-built host), so each
/// bundle is searched at its root and under `Resources/`.
@available(macOS 15.0, *)
enum BundledResource {
    static func url(forResource name: String, withExtension ext: String) -> URL? {
        let candidates: [Bundle] = [
            Bundle.module,
            Bundle(for: BundleAnchor.self),
        ] + Bundle.allBundles + Bundle.allFrameworks

        for bundle in candidates {
            if let url = find(name, ext, in: bundle) { return url }
            // Host apps may also embed this module's resource bundle as a sibling .bundle; open it explicitly and
            // search inside.
            if let nestedURL = bundle.url(
                forResource: "swift-sheet-music_SheetMusicLayoutApple",
                withExtension: "bundle",
            ),
                let nested = Bundle(url: nestedURL),
                let url = find(name, ext, in: nested)
            {
                return url
            }
        }
        return nil
    }

    private static func find(_ name: String, _ ext: String, in bundle: Bundle) -> URL? {
        bundle.url(forResource: name, withExtension: ext)
            ?? bundle.url(forResource: name, withExtension: ext, subdirectory: "Resources")
    }
}

/// Private anchor used by `Bundle(for:)` to locate the binary that contains this module's code (and, by convention,
/// its resource bundle). Not exposed — existence is an implementation detail.
@available(macOS 15.0, *)
private final class BundleAnchor {}
