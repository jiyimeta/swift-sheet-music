import SheetMusicLayout
import SwiftUI

/// A jump is its text's runs, hung by the jump anchor. One without runs draws nothing.
@available(macOS 15.0, *)
enum JumpRenderer {
    static func draw(context: inout GraphicsContext, origin: CGPoint, richText: LayoutRichText?) {
        guard let richText else { return }
        TextInkRenderer.drawRich(
            context: &context, richText: richText, origin: origin,
            anchor: LayoutRichText.anchor(for: .jump), color: .primary,
        )
    }
}
