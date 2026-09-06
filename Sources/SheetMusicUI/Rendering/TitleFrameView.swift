import SheetMusicCore
import SheetMusicLayout
import SwiftUI

/// SwiftUI view that paints a `LayoutTitleFrame` via `Canvas`.
/// `ScoreView`'s vertical and horizontal stacks place an instance
/// at the document's top-leading corner so the title block sits
/// above the first system in the same coordinate space the layout
/// engine produced.
@available(macOS 15.0, *)
struct TitleFrameView: View {
    let frame: LayoutTitleFrame
    let width: CGFloat

    var body: some View {
        Canvas(opaque: true) { context, size in
            // White background — staff drawing assumes a white
            // canvas; the title block sits on the same paper.
            //
            // Fill the size the canvas was actually LAID OUT at,
            // not the width asked for below. `opaque: true` says
            // this canvas paints every one of its pixels, so the
            // backing is never cleared — and a pixel the fill does
            // not reach stays black. When the two sizes disagree
            // by a rounding step (a page scaled to fit, a
            // fractional document width), that difference is a
            // black hairline down the trailing edge of the title
            // block, the exact height of the frame and nowhere
            // else on the page.
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(.white),
            )
            TitleFrameRenderer.draw(frame, into: &context)
        }
        .frame(width: width, height: frame.height)
        .environment(\.colorScheme, .light)
    }
}
