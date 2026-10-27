import CoreText
import Foundation
import os

/// Runtime font registration for text faces the score model refers
/// to (e.g. `face: "Edwin"`). Bravura is bundled and registered
/// automatically by `BravuraFont`; everything else is opt-in: the
/// host application supplies the font URLs at launch.
///
/// Recommended use — let MuseScore-style scores render with their
/// intended typography by registering Edwin (OFL) on launch:
///
/// ```swift
/// // App.init()
/// let urls = Bundle.main.urls(
///     forResourcesWithExtension: "otf",
///     subdirectory: "Fonts"
/// ) ?? []
/// SheetMusicFonts.register(urls: urls)
/// ```
///
/// When a face referenced by the score is **not** registered,
/// CoreText silently falls back to the platform system font, so
/// rendering keeps working — just without the MuseScore-matching
/// look.
@available(macOS 15.0, *)
public enum SheetMusicFonts {
    private static let logger = Logger(
        subsystem: "swift-sheet-music.SheetMusicLayoutApple",
        category: "Fonts",
    )

    /// The portable font-metrics table this module bundles, `sheet-music-styled.smft`: the table Android and Windows
    /// lay out with (a copy of `Sources/SheetMusicRenderWindows/Resources/sheet-music.smft`), whose Edwin bold and
    /// italic records measure the family's own styled faces. Lay a computation out with it where its picture must be
    /// the one those platforms draw — scoped to that computation, never installed over the app's CoreText provider:
    ///
    /// ```swift
    /// guard let tableURL = SheetMusicFonts.portableMetricsTableURL else { return }
    /// let table = try fontMetricsTableProvider(Data(contentsOf: tableURL)) // SheetMusicPages
    /// let pages = FontMetrics.withProvider(table) {
    ///     ScorePages.compute(score: score, pageWidthMM: 210, pageHeightMM: 297)
    /// }
    /// ```
    ///
    /// The table measures every text face as Edwin, so the text is drawn right only where the host registered
    /// Edwin's faces (`register(urls:)`). `nil` only when the module's resource bundle is missing from the host.
    public static let portableMetricsTableURL: URL? = BundledResource.url(
        forResource: "sheet-music-styled", withExtension: "smft",
    )

    /// The Bravura font file this module bundles, which `BravuraFont.register` registers: the bytes a PDF written in
    /// Swift embeds as its music face (`ScorePDFFonts(smufl:…)`, SheetMusicPDFWriter). `nil` only when the module's
    /// resource bundle is missing from the host.
    public static let bravuraURL: URL? = BundledResource.url(forResource: "Bravura", withExtension: "otf")

    /// Register one or more font files with CoreText for the lifetime
    /// of this process. Idempotent — already-registered URLs are
    /// reported as success.
    ///
    /// - Returns: the URLs that were registered successfully (or were
    ///   already registered). Diagnostic logs note any failures.
    @discardableResult
    public static func register(urls: [URL]) -> [URL] {
        var registered: [URL] = []
        for url in urls where registerOne(url: url) {
            registered.append(url)
        }
        return registered
    }

    private static func registerOne(url: URL) -> Bool {
        var error: Unmanaged<CFError>?
        let ok = CTFontManagerRegisterFontsForURL(
            url as CFURL, .process, &error,
        )
        if ok {
            logger.info("Registered font \(url.lastPathComponent, privacy: .public)")
            return true
        }
        // 105 = kCTFontManagerErrorAlreadyRegistered — not actually
        // an error in our use case.
        if let cfErr = error?.takeUnretainedValue(),
           CFErrorGetCode(cfErr) == 105
        {
            logger.info(
                "Font \(url.lastPathComponent, privacy: .public) already registered",
            )
            return true
        }
        let desc = error?.takeRetainedValue().localizedDescription
            ?? "unknown CTFontManager error"
        logger.error(
            "Failed to register \(url.lastPathComponent, privacy: .public): \(desc, privacy: .public)",
        )
        return false
    }
}
