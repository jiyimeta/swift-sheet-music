import SheetMusicCore
import SheetMusicLayout
import SwiftUI

/// SwiftUI view that paints a `LayoutTitleFrame` via `Canvas`.
/// `ScoreView`'s vertical and horizontal stacks place an instance
/// at the document's top-leading corner so the title block sits
/// above the first system in the same coordinate space the layout
/// engine produced.
@available(macOS 15.0, iOS 16.0, *)
struct TitleFrameView: View {
    let frame: LayoutTitleFrame
    let width: CGFloat

    var body: some View {
        Canvas(opaque: true) { context, _ in
            // White background — staff drawing assumes a white
            // canvas; the title block sits on the same paper.
            context.fill(
                Path(CGRect(
                    origin: .zero,
                    size: CGSize(width: width, height: frame.height))),
                with: .color(.white))
            TitleFrameRenderer.draw(frame, into: &context)
        }
        .frame(width: width, height: frame.height)
        .environment(\.colorScheme, .light)
    }
}
