import SheetMusicLayout
import SwiftUI

/// The boxes of a document in `ScoreView`'s stacks: the title block with its pictures, and the boxes between systems.
@available(macOS 15.0, *)
extension ScoreView {
    /// The title block with its pictures (`LayoutDocument.titleImages`, in document coordinates, so the block sits at
    /// the document's top-leading corner with no offset). Never culled, in either mode.
    @ViewBuilder
    static func titleBlock(of doc: LayoutDocument) -> some View {
        if let titleFrame = doc.titleFrame {
            FrameContentView(
                frame: titleFrame, images: doc.titleImages, width: doc.size.width, height: titleFrame.height,
            )
        }
    }

    /// The boxes between systems that `visibleRect` meets, each at its `originY` (its texts and pictures are relative
    /// to that top), identified by its index in the WHOLE document as the systems are, so a box keeps its view as
    /// others mount and unmount around it.
    static func mountedFrames(of doc: LayoutDocument, in visibleRect: CGRect?) -> some View {
        ForEach(mountedFrameIndices(of: doc, in: visibleRect), id: \.self) { index in
            let frame = doc.frames[index]
            FrameContentView(
                frame: frame.content, images: frame.images, width: doc.size.width, height: frame.height,
            )
            .offset(y: frame.originY)
        }
    }

    /// Indices of the boxes between systems (`LayoutDocument.frames`) that `visibleRect` meets, by
    /// `mountedSystemIndices`' test: a box counts one point taller than it is — every index when the rect is `nil`.
    nonisolated static func mountedFrameIndices(of doc: LayoutDocument, in visibleRect: CGRect?) -> [Int] {
        guard let visibleRect else { return Array(doc.frames.indices) }
        return doc.frames.indices.filter { index in
            let frame = doc.frames[index]
            return frame.originY + frame.height + 1 >= visibleRect.minY && frame.originY <= visibleRect.maxY
        }
    }
}
