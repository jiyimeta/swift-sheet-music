import Foundation

/// The files a Windows host needs beside the code: the five faces the renderer draws with (Bravura, and Edwin's
/// roman, italic, bold and bold italic — bold and italic are never synthesized) and the metrics table the layout
/// measures them by (`sheet-music.smft`), shipped with this module so they always match its revision.
/// `Resources/README.md` says where each comes from; `SheetMusicTests`' `WindowsBundledResourcesTests` pins each to its
/// source on every Mac run.
///
/// They sit in SwiftPM's resource bundle for this target, the folder
/// `swift-sheet-music_SheetMusicRenderWindows.resources` that `swift build` writes beside the executable. **A deployed
/// app must carry that folder beside its executable too** (in its MSIX, its zip, its installer). `Bundle.module` looks
/// there first and then in the build directory the module was compiled in; when neither has it, SwiftPM's generated
/// accessor stops the process with `fatalError`.
enum BundledResources {
    /// The folder `.copy("Resources")` puts inside the bundle.
    static let folder = "Resources"
    static let fontFileNames = [
        "Bravura.otf", "Edwin-Roman.otf", "Edwin-Italic.otf", "Edwin-Bold.otf", "Edwin-BdIta.otf",
    ]
    static let metricsTableFileName = "sheet-music.smft"

    /// The bundled file `name`, whether or not it exists.
    ///
    /// Built from `bundleURL` rather than asked of `url(forResource:withExtension:subdirectory:)`: off Apple the
    /// bundle is a bare folder, and CoreFoundation guesses a bundle's shape from its subfolders — one with
    /// `Resources/` reads as an old-style bundle whose resources root is that folder — so where a lookup lands would
    /// hang on the guess. A path has no guess in it.
    static func url(_ name: String) -> URL {
        Bundle.module.bundleURL
            .appendingPathComponent(folder, isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
    }
}

extension ScoreSurface {
    /// The bundled faces' paths — Bravura, then Edwin roman, italic, bold and bold italic — for `init(fontFiles:)`
    /// and `Direct2DPageRenderer.renderPNG(pages:page:pxPerMM:fontFiles:to:)`.
    ///
    /// Reading it loads `Bundle.module`, which stops the process when the resource bundle is missing (see
    /// `BundledResources`).
    public static var bundledFontFiles: [String] {
        BundledResources.fontFileNames.map { BundledResources.url($0).path }
    }

    /// A surface that draws with the faces bundled with this module: `init(fontFiles: ScoreSurface.bundledFontFiles)`.
    /// A host that ships its own copies passes them to `init(fontFiles:)` instead.
    ///
    /// Throws as `init(fontFiles:)` does — among other things when a bundled face is not in the resource bundle.
    public convenience init() throws {
        try self.init(fontFiles: ScoreSurface.bundledFontFiles)
    }
}

/// `installWindowsFontMetrics(tableBytes:)` with the table bundled with this module, which matches this package's
/// revision by construction. Call it once, before the first layout. A host that ships its own table calls
/// `installWindowsFontMetrics(tableBytes:)` with it instead.
///
/// Throws when the bundled table cannot be read or does not decode, or DirectWrite cannot resolve Segoe UI; the
/// provider is left as it was. Loads `Bundle.module`, which stops the process when the resource bundle is missing.
public func installWindowsFontMetrics() throws {
    let table = try Data(contentsOf: BundledResources.url(BundledResources.metricsTableFileName))
    try installWindowsFontMetrics(tableBytes: table)
}
