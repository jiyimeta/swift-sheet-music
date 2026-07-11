import Foundation
import SheetMusicAudio

/// Resolves SoundFonts for the example app.
///
/// * Per-(bank, program) split files at `Sounds/BBB_PPP.sf2` are looked
///   up lazily (tiny per-patch files keep iPhone memory low), where
///   `BBB`/`PPP` are three-digit decimals and the drum bank is `128`.
/// * The full-GM fallback is whatever full SoundFont the user selected
///   in the picker (see `SoundfontCatalog`) — no file name is hard-coded
///   here. `nil` when `Sounds/` has no selectable font, in which case the
///   engine stays silent.
///
/// SoundFont files are distributed via each font's own source (they are
/// too large for git); see README §"SoundFonts".
struct SelectableSoundfontResolver: SoundfontResolver {
    let gmSoundfontURL: URL?
    private let bundle: Bundle = .main

    func soundfontURL(forBank bank: UInt8, program: UInt8, isDrums: Bool) -> URL? {
        let bankPrefix = isDrums ? 128 : Int(bank)
        let name = String(format: "%03d_%03d", bankPrefix, program)
        return bundle.url(
            forResource: name, withExtension: "sf2", subdirectory: "Sounds",
        )
    }

    var defaultGMSoundfontURL: URL? {
        gmSoundfontURL
    }
}
