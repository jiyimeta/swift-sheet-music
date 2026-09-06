import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension PositionedScoreBlock {
    /// Every box in the first top-level `<Staff>` body, in document order.
    static func decodeAll(inTopLevelStaff node: XMLTreeNode) -> [PositionedScoreBlock] {
        var beforeMeasureIndex = 0
        var blocks: [PositionedScoreBlock] = []

        for child in node.children {
            // This index addresses `Staff.measures`, so only a `<Measure>`
            // that becomes one advances it. A multi-measure-rest container
            // is a `<Measure>` element that the staff decoder never retains.
            if child.name == "Measure" {
                if !Measure.isMultiMeasureRestContainer(child) {
                    beforeMeasureIndex += 1
                }
                continue
            }

            let block: ScoreBlock
            switch child.name {
            case "VBox":
                block = .verticalFrame(ScoreFrame.decode(vbox: child))
            case "HBox":
                block = .opaqueFrame(OpaqueFrame(
                    kind: .horizontal,
                    preservedMarkup: child.preservedMarkup(consuming: []),
                ))
            case "TBox":
                block = .opaqueFrame(OpaqueFrame(
                    kind: .text,
                    preservedMarkup: child.preservedMarkup(consuming: []),
                ))
            case "FBox":
                block = .opaqueFrame(OpaqueFrame(
                    kind: .fret,
                    preservedMarkup: child.preservedMarkup(consuming: []),
                ))
            default:
                continue
            }
            blocks.append(PositionedScoreBlock(
                beforeMeasureIndex: beforeMeasureIndex,
                block: block,
            ))
        }
        return blocks
    }
}
