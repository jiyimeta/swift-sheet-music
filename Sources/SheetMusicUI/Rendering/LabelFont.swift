import CoreText
import SheetMusicLayout
import SheetMusicLayoutApple

/// The face of the labels the renderers set in the system's semibold — tuplet numbers, volta labels, the Canvas's
/// measure numbers and staff names — when the current metrics provider draws that face as another one
/// (`RenderingTextFace`).
@available(macOS 15.0, *)
enum LabelFont {
    /// The label face at `size` as the current provider draws it, or nil when it draws the system semibold as asked —
    /// always, under CoreText.
    static func substitute(size: CGFloat, italic: Bool) -> CTFont? {
        RenderingTextFace.substitute(
            for: LayoutFont(face: "", pointSize: size, weight: .semibold, isItalic: italic),
        ).map(RenderingTextFace.ctFont)
    }
}
