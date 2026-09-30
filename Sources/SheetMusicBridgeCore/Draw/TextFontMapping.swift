import SheetMusicLayout

/// Turns the font a layout measured a run in into the wire's face id and `setTextStyle` flags. The one place that
/// decision is made, so a text command always names the face its position was computed from.
///
/// A text command's x already has its anchor resolved against the measured ink width (a right-aligned part label, a
/// centered measure number), and a renderer cannot resolve it again. So a renderer has to draw in the face the layout
/// measured, which is why the id comes from the `LayoutFont` that `FontMetricsProvider.renderingTextFont` returned and
/// never from the text's role: a role-derived id lets a reader measure Edwin and draw Segoe UI, and a right-aligned
/// label then runs into the staff.
package enum TextFontMapping {
    /// - `SMuFLFamily.bravura` → `.smufl`; the empty face (the platform UI family) → `.system`; any other face →
    ///   `.textRoman`.
    /// - `FontWeight` maps one-to-one onto the style bits: `.bold` → `bold`, `.semibold` → `semibold`, `.regular` →
    ///   neither. `isItalic` adds `italic`.
    package static func wire(for font: LayoutFont) -> (fontId: DrawProgram.FontID, style: UInt8) {
        let fontId: DrawProgram.FontID = if font.face == SMuFLFamily.bravura {
            .smufl
        } else if font.face.isEmpty {
            .system
        } else {
            .textRoman
        }
        var style = DrawCommand.TextStyleFlag.none
        switch font.weight {
        case .regular: break
        case .semibold: style |= DrawCommand.TextStyleFlag.semibold
        case .bold: style |= DrawCommand.TextStyleFlag.bold
        }
        if font.isItalic {
            style |= DrawCommand.TextStyleFlag.italic
        }
        return (fontId, style)
    }
}
