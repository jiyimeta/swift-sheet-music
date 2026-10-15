#if canImport(CoreGraphics)
    import CoreGraphics
#endif
import SheetMusicCore

extension LayoutEngine {
    /// A dynamic's layout element, `origin` being where a plain dynamic's glyphs hang (leading edge, vertical center of
    /// their em box). One printing its subtype is the glyph element it always was. One with its own text
    /// (`Dynamic.displayedRichText`: "subito p", "più ⟨f⟩", an `other-dynamics` word) carries its runs instead
    /// (`LayoutRichText.dynamic`), starting at the same X with its first baseline on the plain glyphs' baseline —
    /// MuseScore sets every dynamic on one baseline (`Sid::dynamicsAlign`, `engraving/style/styledef.cpp:1119`).
    static func dynamicElement(
        _ dynamic: Dynamic, anchor: VoiceElementID?, origin: CGPoint, metrics: StaffMetrics,
    ) -> LayoutElement {
        guard let displayed = dynamic.displayedRichText else {
            return .textMark(kind: .dynamic(anchor: anchor), text: dynamic.subtype, origin: origin)
        }
        let rich = LayoutRichText.dynamic(displayed, properties: dynamic.properties, metrics: metrics)
        let glyphFont = LayoutFont(
            face: SMuFLFamily.bravura, pointSize: LayoutRichText.dynamicSymbolPointSize(metrics: metrics),
        )
        let baseline = LayoutElementShape.baselineY(font: glyphFont, originY: origin.y, anchor: .leadingCenter)
        // `text` is the element's label for whatever reads one; a text of glyphs alone has no plain words, so the
        // subtype names it.
        return .textMark(
            kind: .dynamic(anchor: anchor),
            text: displayed.plainText.isEmpty ? dynamic.subtype : displayed.plainText,
            origin: rich.origin(
                firstBaselineAt: CGPoint(x: origin.x, y: baseline), anchor: LayoutRichText.anchor(for: .dynamic),
            ),
            richText: rich,
        )
    }
}
