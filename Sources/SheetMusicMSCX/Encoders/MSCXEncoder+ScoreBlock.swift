import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension ScoreBlock {
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        switch self {
        case let .verticalFrame(frame):
            return frame.encodeAsVBox(options: options)
        case let .opaqueFrame(frame):
            var children: [XMLTreeNode] = []
            appendPreservedMarkup(
                frame.preservedMarkup,
                to: &children,
                options: options,
            )
            return XMLTreeNode(name: frame.kind.rawValue, children: children)
        }
    }
}
