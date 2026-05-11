import Foundation

/// Paper size and per-edge margins, in MuseScore's native units.
/// All linear values are **inches**. The right margin is *not* stored
/// — it is derived from `(width − printableWidth) − leftMargin`,
/// mirroring `Page::rm` (`engraving/dom/page.cpp:207-209`).
public struct PageLayout: Sendable, Equatable {
    public var width: Double // inches; C++ Sid::pageWidth
    public var height: Double // inches; C++ Sid::pageHeight
    public var printableWidth: Double // inches; C++ Sid::pagePrintableWidth
    public var oddTopMargin: Double // inches
    public var oddBottomMargin: Double // inches
    public var oddLeftMargin: Double // inches
    public var evenTopMargin: Double // inches
    public var evenBottomMargin: Double // inches
    public var evenLeftMargin: Double // inches
    /// `true` → odd pages use `odd*Margin`, even pages use
    /// `even*Margin`. `false` → every page uses the odd values.
    /// MuseScore default `true`. C++ `Sid::pageTwosided`.
    public var twosided: Bool

    public init(
        width: Double,
        height: Double,
        printableWidth: Double,
        oddTopMargin: Double,
        oddBottomMargin: Double,
        oddLeftMargin: Double,
        evenTopMargin: Double,
        evenBottomMargin: Double,
        evenLeftMargin: Double,
        twosided: Bool,
    ) {
        self.width = width
        self.height = height
        self.printableWidth = printableWidth
        self.oddTopMargin = oddTopMargin
        self.oddBottomMargin = oddBottomMargin
        self.oddLeftMargin = oddLeftMargin
        self.evenTopMargin = evenTopMargin
        self.evenBottomMargin = evenBottomMargin
        self.evenLeftMargin = evenLeftMargin
        self.twosided = twosided
    }

    /// Right margin on odd pages, derived per `Page::rm`.
    /// May go negative if the source file has
    /// `printableWidth + leftMargin > width`; we don't clamp.
    public var oddRightMargin: Double {
        width - printableWidth - oddLeftMargin
    }

    /// Right margin on even pages, derived per `Page::rm`.
    public var evenRightMargin: Double {
        width - printableWidth - evenLeftMargin
    }

    /// MuseScore's default A4: 210 × 297 mm, 15 mm margins
    /// (180 mm printable width = page − 2 × 15 mm), two-sided.
    /// Source: `engraving/style/styledef.cpp:41-50`.
    public static let museScoreA4 = PageLayout(
        width: 210.0 / 25.4,
        height: 297.0 / 25.4,
        printableWidth: 180.0 / 25.4,
        oddTopMargin: 15.0 / 25.4,
        oddBottomMargin: 15.0 / 25.4,
        oddLeftMargin: 15.0 / 25.4,
        evenTopMargin: 15.0 / 25.4,
        evenBottomMargin: 15.0 / 25.4,
        evenLeftMargin: 15.0 / 25.4,
        twosided: true,
    )
}
