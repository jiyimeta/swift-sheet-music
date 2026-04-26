import Foundation
import SheetMusicAudio

/// Looks SoundFonts up in the app bundle.
///
/// Convention used by the example app — matches the layout produced
/// by https://github.com/jiyimeta/musescore-general-sf2-split:
///
///   * `Sounds/BBB_PPP.sf2` — per-(bank, program) files, where BBB
///     and PPP are three-digit decimal numbers (e.g. `000_000.sf2`
///     for Acoustic Grand Piano on bank 0).
///   * `Sounds/MuseScore_General.sf2` — the full GM fallback,
///     consulted when no per-program file matches.
///
/// Both are distributed via GitHub Releases (too large for git);
/// see README §"SoundFonts" for download instructions. When neither
/// file is present, the resolver returns `nil`, the `PlaybackEngine`
/// keeps its sampler graph intact, and you'll see the score without
/// hearing it.
struct BundledSoundfontResolver: SoundfontResolver {
    private let bundle: Bundle = .main

    func soundfontURL(forBank bank: UInt8, program: UInt8) -> URL? {
        let name = String(format: "%03d_%03d", bank, program)
        return bundle.url(
            forResource: name,
            withExtension: "sf2",
            subdirectory: "Sounds")
    }

    var defaultGMSoundfontURL: URL? {
        bundle.url(
            forResource: "MuseScore_General",
            withExtension: "sf2",
            subdirectory: "Sounds")
    }
}
