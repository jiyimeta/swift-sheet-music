import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension ScoreStyle {
    /// Parse a `<Style>` element. Permissive — unrecognised children
    /// are silently ignored, matching the existing
    /// `MSCXDecoder+Voice` convention. Returns the MuseScore default
    /// for any field the XML does not specify.
    ///
    /// MuseScore stores page geometry in **inches** and spatium in
    /// **millimetres**; we keep both in their native units so the
    /// values round-trip with what MuseScore writes. See
    /// `engraving/style/style.cpp:120-156, 385-386` for the read
    /// path.
    static func decode(style node: XMLTreeNode) -> ScoreStyle {
        var s = ScoreStyle.museScoreDefaults
        decodePageLayout(node, into: &s.pageLayout)
        decodeSpatium(node, into: &s.spatium)
        decodeChrome(node, into: &s.pageChrome)
        return s
    }
}

private func decodePageLayout(
    _ node: XMLTreeNode, into layout: inout PageLayout
) {
    if let v = node.firstDouble("pageWidth") { layout.width = v }
    if let v = node.firstDouble("pageHeight") { layout.height = v }
    if let v = node.firstDouble("pagePrintableWidth") { layout.printableWidth = v }
    if let v = node.firstDouble("pageOddTopMargin") { layout.oddTopMargin = v }
    if let v = node.firstDouble("pageOddBottomMargin") { layout.oddBottomMargin = v }
    if let v = node.firstDouble("pageOddLeftMargin") { layout.oddLeftMargin = v }
    if let v = node.firstDouble("pageEvenTopMargin") { layout.evenTopMargin = v }
    if let v = node.firstDouble("pageEvenBottomMargin") { layout.evenBottomMargin = v }
    if let v = node.firstDouble("pageEvenLeftMargin") { layout.evenLeftMargin = v }
    if let v = node.firstBool("pageTwosided") { layout.twosided = v }
}

private func decodeSpatium(
    _ node: XMLTreeNode, into spatium: inout Double
) {
    // MuseScore writes capital "Spatium" today (engraving-style XML)
    // but `style.cpp:385-386` accepts both forms; older fixtures use
    // lowercase. We mirror that compatibility.
    if let v = node.firstDouble("Spatium") { spatium = v; return }
    if let v = node.firstDouble("spatium") { spatium = v }
}

private func decodeChrome(
    _ node: XMLTreeNode, into chrome: inout PageChrome
) {
    decodeHeader(node, into: &chrome.header)
    decodeFooter(node, into: &chrome.footer)
    decodePageNumber(node, into: &chrome.pageNumber)
}

private func decodeHeader(
    _ node: XMLTreeNode, into header: inout HeaderFooter
) {
    if let v = node.firstBool("showHeader") { header.enabled = v }
    if let v = node.firstBool("headerFirstPage") { header.showOnFirstPage = v }
    if let v = node.firstBool("headerOddEven") { header.oddEvenDifferent = v }
    if let v = node.first("evenHeaderL")?.text { header.even.left = v }
    if let v = node.first("evenHeaderC")?.text { header.even.center = v }
    if let v = node.first("evenHeaderR")?.text { header.even.right = v }
    if let v = node.first("oddHeaderL")?.text { header.odd.left = v }
    if let v = node.first("oddHeaderC")?.text { header.odd.center = v }
    if let v = node.first("oddHeaderR")?.text { header.odd.right = v }
    if let v = node.first("headerFontFace")?.text { header.fontFace = v }
    if let v = node.firstDouble("headerFontSize") { header.fontSize = v }
    if let v = node.firstInt("headerFontStyle") {
        header.fontStyle = FontStyleSet(rawValue: v)
    }
}

private func decodeFooter(
    _ node: XMLTreeNode, into footer: inout HeaderFooter
) {
    if let v = node.firstBool("showFooter") { footer.enabled = v }
    if let v = node.firstBool("footerFirstPage") { footer.showOnFirstPage = v }
    if let v = node.firstBool("footerOddEven") { footer.oddEvenDifferent = v }
    if let v = node.first("evenFooterL")?.text { footer.even.left = v }
    if let v = node.first("evenFooterC")?.text { footer.even.center = v }
    if let v = node.first("evenFooterR")?.text { footer.even.right = v }
    if let v = node.first("oddFooterL")?.text { footer.odd.left = v }
    if let v = node.first("oddFooterC")?.text { footer.odd.center = v }
    if let v = node.first("oddFooterR")?.text { footer.odd.right = v }
    if let v = node.first("footerFontFace")?.text { footer.fontFace = v }
    if let v = node.firstDouble("footerFontSize") { footer.fontSize = v }
    if let v = node.firstInt("footerFontStyle") {
        footer.fontStyle = FontStyleSet(rawValue: v)
    }
}

private func decodePageNumber(
    _ node: XMLTreeNode, into pn: inout PageNumberStyle
) {
    if let v = node.firstBool("showPageNumber") { pn.enabled = v }
    if let v = node.firstBool("showPageNumberOne") { pn.showOnFirstPage = v }
    if let v = node.firstBool("pageNumberOddEven") { pn.oddEvenDifferent = v }
    if let v = node.first("pageNumberFontFace")?.text { pn.fontFace = v }
    if let v = node.firstDouble("pageNumberFontSize") { pn.fontSize = v }
}

extension XMLTreeNode {
    fileprivate func firstDouble(_ name: String) -> Double? {
        guard let raw = first(name)?.text else { return nil }
        return Double(raw)
    }

    fileprivate func firstInt(_ name: String) -> Int? {
        guard let raw = first(name)?.text else { return nil }
        return Int(raw)
    }

    /// MuseScore writes booleans as `0` / `1`; treat anything
    /// non-zero as `true` to match upstream.
    fileprivate func firstBool(_ name: String) -> Bool? {
        guard let raw = first(name)?.text, let n = Int(raw) else {
            return nil
        }
        return n != 0
    }
}
