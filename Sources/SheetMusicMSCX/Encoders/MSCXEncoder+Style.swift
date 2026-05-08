import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension ScoreStyle {
    /// Build the `<Style>` block. Emits page geometry, spatium, and
    /// the page-level chrome (header / footer / page numbers) in the
    /// same field order MuseScore writes — see
    /// `engraving/style/styledef.cpp`. Each per-field child is gated
    /// on `value != ScoreStyle.museScoreDefaults.<field>` so the
    /// emitted XML matches MuseScore Studio's terse output. Spatium
    /// is always emitted (MuseScore's writer also always anchors
    /// it). The decoder overlays the same defaults, so elided fields
    /// round-trip back to the same value.
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        let defaults = ScoreStyle.museScoreDefaults
        var children: [XMLTreeNode] = []
        appendPageLayout(pageLayout, defaults: defaults.pageLayout, into: &children)
        // Spatium is unconditionally emitted: MuseScore Studio always
        // writes a `<spatium>` anchor, and downstream readers expect
        // it as the canonical place to discover engraving units.
        children.append(double("spatium", spatium))
        appendHeader(
            pageChrome.header,
            defaults: defaults.pageChrome.header,
            into: &children
        )
        appendFooter(
            pageChrome.footer,
            defaults: defaults.pageChrome.footer,
            into: &children
        )
        appendPageNumber(
            pageChrome.pageNumber,
            defaults: defaults.pageChrome.pageNumber,
            into: &children
        )
        return XMLTreeNode(name: "Style", children: children)
    }
}

private func appendPageLayout(
    _ layout: PageLayout,
    defaults d: PageLayout,
    into children: inout [XMLTreeNode]
) {
    emitIfNotDefault("pageWidth", layout.width, default: d.width, double, into: &children)
    emitIfNotDefault("pageHeight", layout.height, default: d.height, double, into: &children)
    emitIfNotDefault("pagePrintableWidth", layout.printableWidth, default: d.printableWidth, double, into: &children)
    emitIfNotDefault("pageOddTopMargin", layout.oddTopMargin, default: d.oddTopMargin, double, into: &children)
    emitIfNotDefault("pageOddBottomMargin", layout.oddBottomMargin, default: d.oddBottomMargin, double, into: &children)
    emitIfNotDefault("pageOddLeftMargin", layout.oddLeftMargin, default: d.oddLeftMargin, double, into: &children)
    emitIfNotDefault("pageEvenTopMargin", layout.evenTopMargin, default: d.evenTopMargin, double, into: &children)
    emitIfNotDefault(
        "pageEvenBottomMargin", layout.evenBottomMargin,
        default: d.evenBottomMargin, double, into: &children
    )
    emitIfNotDefault("pageEvenLeftMargin", layout.evenLeftMargin, default: d.evenLeftMargin, double, into: &children)
    emitIfNotDefault("pageTwosided", layout.twosided, default: d.twosided, bool, into: &children)
}

private func appendHeader(
    _ header: HeaderFooter,
    defaults d: HeaderFooter,
    into children: inout [XMLTreeNode]
) {
    emitIfNotDefault("showHeader", header.enabled, default: d.enabled, bool, into: &children)
    emitIfNotDefault("headerFirstPage", header.showOnFirstPage, default: d.showOnFirstPage, bool, into: &children)
    emitIfNotDefault("headerOddEven", header.oddEvenDifferent, default: d.oddEvenDifferent, bool, into: &children)
    if header.oddEvenDifferent {
        // Even-side fields are dead state when oddEvenDifferent is
        // false — MuseScore omits them entirely in that mode.
        emitIfNotDefault("evenHeaderL", header.even.left, default: d.even.left, text, into: &children)
        emitIfNotDefault("evenHeaderC", header.even.center, default: d.even.center, text, into: &children)
        emitIfNotDefault("evenHeaderR", header.even.right, default: d.even.right, text, into: &children)
    }
    emitIfNotDefault("oddHeaderL", header.odd.left, default: d.odd.left, text, into: &children)
    emitIfNotDefault("oddHeaderC", header.odd.center, default: d.odd.center, text, into: &children)
    emitIfNotDefault("oddHeaderR", header.odd.right, default: d.odd.right, text, into: &children)
    emitIfNotDefault("headerFontFace", header.fontFace, default: d.fontFace, text, into: &children)
    emitIfNotDefault("headerFontSize", header.fontSize, default: d.fontSize, double, into: &children)
    emitIfNotDefault("headerFontStyle", header.fontStyle.rawValue, default: d.fontStyle.rawValue, int, into: &children)
}

private func appendFooter(
    _ footer: HeaderFooter,
    defaults d: HeaderFooter,
    into children: inout [XMLTreeNode]
) {
    emitIfNotDefault("showFooter", footer.enabled, default: d.enabled, bool, into: &children)
    emitIfNotDefault("footerFirstPage", footer.showOnFirstPage, default: d.showOnFirstPage, bool, into: &children)
    emitIfNotDefault("footerOddEven", footer.oddEvenDifferent, default: d.oddEvenDifferent, bool, into: &children)
    if footer.oddEvenDifferent {
        emitIfNotDefault("evenFooterL", footer.even.left, default: d.even.left, text, into: &children)
        emitIfNotDefault("evenFooterC", footer.even.center, default: d.even.center, text, into: &children)
        emitIfNotDefault("evenFooterR", footer.even.right, default: d.even.right, text, into: &children)
    }
    emitIfNotDefault("oddFooterL", footer.odd.left, default: d.odd.left, text, into: &children)
    emitIfNotDefault("oddFooterC", footer.odd.center, default: d.odd.center, text, into: &children)
    emitIfNotDefault("oddFooterR", footer.odd.right, default: d.odd.right, text, into: &children)
    emitIfNotDefault("footerFontFace", footer.fontFace, default: d.fontFace, text, into: &children)
    emitIfNotDefault("footerFontSize", footer.fontSize, default: d.fontSize, double, into: &children)
    emitIfNotDefault("footerFontStyle", footer.fontStyle.rawValue, default: d.fontStyle.rawValue, int, into: &children)
}

private func appendPageNumber(
    _ pn: PageNumberStyle,
    defaults d: PageNumberStyle,
    into children: inout [XMLTreeNode]
) {
    emitIfNotDefault("showPageNumber", pn.enabled, default: d.enabled, bool, into: &children)
    emitIfNotDefault("showPageNumberOne", pn.showOnFirstPage, default: d.showOnFirstPage, bool, into: &children)
    emitIfNotDefault("pageNumberOddEven", pn.oddEvenDifferent, default: d.oddEvenDifferent, bool, into: &children)
    emitIfNotDefault("pageNumberFontFace", pn.fontFace, default: d.fontFace, text, into: &children)
    emitIfNotDefault("pageNumberFontSize", pn.fontSize, default: d.fontSize, double, into: &children)
}

/// Append `formatter(name, value)` only when `value != defaultValue`.
/// Centralises the skip-if-default rule so each per-field call site
/// reads as a single line.
private func emitIfNotDefault<T: Equatable>(
    _ name: String,
    _ value: T,
    default defaultValue: T,
    _ formatter: (String, T) -> XMLTreeNode,
    into children: inout [XMLTreeNode]
) {
    guard value != defaultValue else { return }
    children.append(formatter(name, value))
}

private func double(_ name: String, _ value: Double) -> XMLTreeNode {
    // Swift's default `String(Double)` emits the shortest decimal
    // that re-parses back to the same Double, so round-trip equality
    // holds for arbitrary page-layout values; `%g`'s 6-digit default
    // would clip A3 dimensions like 11.6929… to 11.6929.
    XMLTreeNode(name: name, text: String(value))
}

private func int(_ name: String, _ value: Int) -> XMLTreeNode {
    XMLTreeNode(name: name, text: String(value))
}

private func bool(_ name: String, _ value: Bool) -> XMLTreeNode {
    XMLTreeNode(name: name, text: value ? "1" : "0")
}

private func text(_ name: String, _ value: String) -> XMLTreeNode {
    XMLTreeNode(name: name, text: value)
}
