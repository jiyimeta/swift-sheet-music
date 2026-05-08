import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension ScoreStyle {
    /// Build the `<Style>` block. Emits page geometry, spatium, and
    /// the page-level chrome (header / footer / page numbers) in the
    /// same field order MuseScore writes — see
    /// `engraving/style/styledef.cpp`. All fields are emitted
    /// unconditionally so any non-default value round-trips through
    /// `MSCXDecoder+Style`; "skip if equal to default" emission is
    /// deferred to Phase 3.
    func encode() -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        appendPageLayout(pageLayout, into: &children)
        children.append(double("spatium", spatium))
        appendHeader(pageChrome.header, into: &children)
        appendFooter(pageChrome.footer, into: &children)
        appendPageNumber(pageChrome.pageNumber, into: &children)
        return XMLTreeNode(name: "Style", children: children)
    }
}

private func appendPageLayout(
    _ layout: PageLayout, into children: inout [XMLTreeNode]
) {
    children.append(double("pageWidth", layout.width))
    children.append(double("pageHeight", layout.height))
    children.append(double("pagePrintableWidth", layout.printableWidth))
    children.append(double("pageOddTopMargin", layout.oddTopMargin))
    children.append(double("pageOddBottomMargin", layout.oddBottomMargin))
    children.append(double("pageOddLeftMargin", layout.oddLeftMargin))
    children.append(double("pageEvenTopMargin", layout.evenTopMargin))
    children.append(double("pageEvenBottomMargin", layout.evenBottomMargin))
    children.append(double("pageEvenLeftMargin", layout.evenLeftMargin))
    children.append(bool("pageTwosided", layout.twosided))
}

private func appendHeader(
    _ header: HeaderFooter, into children: inout [XMLTreeNode]
) {
    children.append(bool("showHeader", header.enabled))
    children.append(bool("headerFirstPage", header.showOnFirstPage))
    children.append(bool("headerOddEven", header.oddEvenDifferent))
    children.append(text("evenHeaderL", header.even.left))
    children.append(text("evenHeaderC", header.even.center))
    children.append(text("evenHeaderR", header.even.right))
    children.append(text("oddHeaderL", header.odd.left))
    children.append(text("oddHeaderC", header.odd.center))
    children.append(text("oddHeaderR", header.odd.right))
    children.append(text("headerFontFace", header.fontFace))
    children.append(double("headerFontSize", header.fontSize))
    children.append(int("headerFontStyle", header.fontStyle.rawValue))
}

private func appendFooter(
    _ footer: HeaderFooter, into children: inout [XMLTreeNode]
) {
    children.append(bool("showFooter", footer.enabled))
    children.append(bool("footerFirstPage", footer.showOnFirstPage))
    children.append(bool("footerOddEven", footer.oddEvenDifferent))
    children.append(text("evenFooterL", footer.even.left))
    children.append(text("evenFooterC", footer.even.center))
    children.append(text("evenFooterR", footer.even.right))
    children.append(text("oddFooterL", footer.odd.left))
    children.append(text("oddFooterC", footer.odd.center))
    children.append(text("oddFooterR", footer.odd.right))
    children.append(text("footerFontFace", footer.fontFace))
    children.append(double("footerFontSize", footer.fontSize))
    children.append(int("footerFontStyle", footer.fontStyle.rawValue))
}

private func appendPageNumber(
    _ pn: PageNumberStyle, into children: inout [XMLTreeNode]
) {
    children.append(bool("showPageNumber", pn.enabled))
    children.append(bool("showPageNumberOne", pn.showOnFirstPage))
    children.append(bool("pageNumberOddEven", pn.oddEvenDifferent))
    children.append(text("pageNumberFontFace", pn.fontFace))
    children.append(double("pageNumberFontSize", pn.fontSize))
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
