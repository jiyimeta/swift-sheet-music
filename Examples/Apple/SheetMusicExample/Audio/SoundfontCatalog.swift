import Foundation

/// A user-selectable full-GM SoundFont discovered in the app bundle's
/// `Sounds/` directory. `id` is the file name (a stable picker key);
/// `displayName` is derived from it — no name is hard-coded.
struct SoundfontChoice: Identifiable, Hashable {
    let id: String
    let displayName: String
    let url: URL
}

/// Scans a set of `.sf2` files and returns the selectable full-GM
/// SoundFonts, excluding per-(bank, program) split files.
enum SoundfontCatalog {
    /// Build choices from `.sf2` file URLs (injected so the logic is
    /// testable/reviewable without a bundle). Sorted by file name; the
    /// first element is the default selection.
    static func choices(from urls: [URL]) -> [SoundfontChoice] {
        urls
            .filter { $0.pathExtension.lowercased() == "sf2" }
            .filter { !isSplitFile($0) }
            .map {
                SoundfontChoice(
                    id: $0.lastPathComponent,
                    displayName: displayName(for: $0),
                    url: $0,
                )
            }
            .sorted { $0.id < $1.id }
    }

    /// Scan the app bundle's `Sounds/` subdirectory.
    static func bundledChoices(bundle: Bundle = .main) -> [SoundfontChoice] {
        let urls = bundle.urls(
            forResourcesWithExtension: "sf2", subdirectory: "Sounds",
        ) ?? []
        return choices(from: urls)
    }

    /// Per-program split files are named `BBB_PPP.sf2` (three digits,
    /// underscore, three digits) — resolver internals, not font choices.
    private static func isSplitFile(_ url: URL) -> Bool {
        let base = url.deletingPathExtension().lastPathComponent
        let parts = base.split(
            separator: "_", omittingEmptySubsequences: false,
        )
        return parts.count == 2
            && parts.allSatisfy { $0.count == 3 && $0.allSatisfy(\.isNumber) }
    }

    /// Derive a display name: drop the extension, replace `_` and `-`
    /// with spaces. Pure transform — no hard-coded mapping.
    static func displayName(for url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }
}

#if DEBUG
    // Reviewable examples (also serve as living documentation):
    //   choices(from: ["MuseScore_General.sf2", "GeneralUser-GS.sf2",
    //                  "128_000.sf2", "000_040.sf2"])
    //     → ["GeneralUser-GS.sf2" ("GeneralUser GS"),
    //        "MuseScore_General.sf2" ("MuseScore General")]
    //   (split files 128_000 / 000_040 excluded; sorted by file name)
#endif
