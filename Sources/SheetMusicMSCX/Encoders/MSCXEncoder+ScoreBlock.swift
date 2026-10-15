import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension ScoreBlock {
    func encode(options: MSCXEncoderOptions = .init()) -> XMLTreeNode {
        switch self {
        case let .verticalFrame(frame):
            return frame.encodeAsVBox(options: options)
        case .textFrame:
            // Phase A placeholder; Task 3 encodes the typed TBox.
            return XMLTreeNode(name: "TBox")
        case .horizontalFrame:
            // Phase A placeholder; Task 3 encodes the typed HBox.
            return XMLTreeNode(name: "HBox")
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
