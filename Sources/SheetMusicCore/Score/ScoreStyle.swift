import Foundation

/// Subset of MuseScore's `<Style>` block that affects engraving
/// dimensions. Currently covers page geometry, spatium, and the
/// page-level chrome (header / footer / page numbers).
///
/// Storage units mirror MuseScore's native units so callers see the
/// same numbers MuseScore writes to `.mscx`. Conversion to typographic
/// points happens at I/O boundaries (e.g. `PDFExporter`).
///
/// C++: subset of `mu::engraving::MStyle` (`engraving/style/style.cpp`).
public struct ScoreStyle: Sendable, Equatable {
    /// Staff space in **millimetres**.
    /// C++: `Sid::spatium` (stored internally in DPI units there;
    /// kept as mm here to match the on-disk XML and avoid surprises).
    /// MuseScore default 1.75 mm.
    public var spatium: Double
    public var pageLayout: PageLayout
    public var pageChrome: PageChrome
    /// Global swing subdivision. `.off` (the MuseScore default) means
    /// no swing unless an in-piece `Swing` directive turns it on.
    /// C++: `Sid::swingUnit` (style.cpp / styledef.cpp).
    public var swingUnit: SwingUnit
    /// Global swing ratio in percent. 50 = straight, 60 = MuseScore's
    /// default soft swing. Has no audible effect when `swingUnit` is
    /// `.off`. C++: `Sid::swingRatio`.
    public var swingRatio: Int
    /// Title-block (`<VBox>`) text-style align overrides. `nil`
    /// means use the styledef.cpp default for that role:
    /// title `(center, top)`, subtitle `(center, top)`,
    /// composer `(right, bottom)`, lyricist `(left, bottom)`.
    /// MSCX fields: `<titleAlign>`, `<subtitleAlign>`,
    /// `<composerAlign>`, `<lyricistAlign>` — each holding the
    /// `"horizontal,vertical"` form used by MuseScore.
    public var titleAlign: TextAlign?
    public var subtitleAlign: TextAlign?
    public var composerAlign: TextAlign?
    public var lyricistAlign: TextAlign?

    public init(
        spatium: Double,
        pageLayout: PageLayout,
        pageChrome: PageChrome,
        swingUnit: SwingUnit = .off,
        swingRatio: Int = 60,
        titleAlign: TextAlign? = nil,
        subtitleAlign: TextAlign? = nil,
        composerAlign: TextAlign? = nil,
        lyricistAlign: TextAlign? = nil,
    ) {
        self.spatium = spatium
        self.pageLayout = pageLayout
        self.pageChrome = pageChrome
        self.swingUnit = swingUnit
        self.swingRatio = swingRatio
        self.titleAlign = titleAlign
        self.subtitleAlign = subtitleAlign
        self.composerAlign = composerAlign
        self.lyricistAlign = lyricistAlign
    }

    /// MuseScore's documented defaults: 1.75 mm spatium, A4 paper
    /// with 15 mm margins, two-sided, default header/footer chrome,
    /// swing off (ratio 60 retained as the default-on value).
    public static let museScoreDefaults = ScoreStyle(
        spatium: 1.75,
        pageLayout: .museScoreA4,
        pageChrome: .museScoreDefaults,
        swingUnit: .off,
        swingRatio: 60,
    )
}
