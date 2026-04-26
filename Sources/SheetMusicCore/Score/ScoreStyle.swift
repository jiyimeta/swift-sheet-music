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

    public init(
        spatium: Double,
        pageLayout: PageLayout,
        pageChrome: PageChrome
    ) {
        self.spatium = spatium
        self.pageLayout = pageLayout
        self.pageChrome = pageChrome
    }

    /// MuseScore's documented defaults: 1.75 mm spatium, A4 paper
    /// with 15 mm margins, two-sided, default header/footer chrome.
    public static let museScoreDefaults = ScoreStyle(
        spatium: 1.75,
        pageLayout: .museScoreA4,
        pageChrome: .museScoreDefaults)
}
