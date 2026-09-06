import CoreText
import Foundation
import SheetMusic
import SheetMusicLayout
import SwiftUI

/// Draws the otherwise-nonexistent frame while entering a new mark.
@available(macOS 15.0, *)
struct RehearsalMarkEditingFrame: View {
    let textOrigin: CGPoint
    let sp: CGFloat

    var body: some View {
        if let frameGeometry {
            frameGeometry.path.stroke(
                Color.black,
                lineWidth: frameGeometry.lineWidth,
            )
            .allowsHitTesting(false)
        }
    }

    private var frameGeometry: Geometry? {
        let resolved = EngravedTextFieldFont(
            style: .rehearsalMark,
            sp: sp,
        )
        // An empty CTLine has no run metrics. A zero-width space keeps
        // the advance at zero while resolving the same font ascent and
        // descent as the committed rehearsal-mark renderer.
        let attributed = NSAttributedString(
            string: "\u{200B}",
            attributes: [.font: resolved.ctFont],
        )
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let advance = CGFloat(CTLineGetTypographicBounds(
            line,
            &ascent,
            &descent,
            &leading,
        ))
        let textWidth = max(advance, resolved.pointSize * 0.5)
        let textHeight = ascent + descent
        let pad = RehearsalMarkFrame.paddingSp(sp: sp)
        let frameOrigin = CGPoint(
            x: textOrigin.x - pad,
            y: textOrigin.y + pad,
        )
        let box = RehearsalMarkFrame.boxRect(
            textWidth: textWidth,
            textHeight: textHeight,
            origin: frameOrigin,
            pad: pad,
        )
        let path: Path
        switch RehearsalMarkFrame.shape(
            for: resolved.frameType,
            around: box,
        ) {
        case .none:
            return nil
        case let .rectangle(rect):
            path = Path(rect)
        case let .ellipse(rect):
            path = Path(ellipseIn: rect)
        }
        // This is intentionally an editing affordance, not a faithful
        // score preview: the score contains no empty rehearsal mark.
        return Geometry(
            path: path,
            lineWidth: RehearsalMarkFrame.strokeWidthSp(sp: sp),
        )
    }

    private struct Geometry {
        let path: Path
        let lineWidth: CGFloat
    }
}
