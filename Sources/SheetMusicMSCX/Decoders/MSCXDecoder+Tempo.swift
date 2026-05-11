import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Tempo {
    static func decode(_ node: XMLTreeNode) throws -> Tempo {
        let bps = Double(node.first("tempo")?.text ?? "2") ?? 2.0
        let offset = node.first("offset").map { offsetNode -> (Double, Double) in
            let attrs = offsetNode.attributes
            let x = attrs["x"].flatMap(Double.init) ?? 0
            let y = attrs["y"].flatMap(Double.init) ?? 0
            return (x, y)
        } ?? (0, 0)
        let visible = (node.first("visible")?.text ?? "1") != "0"
        return Tempo(
            beatsPerSecond: bps,
            offsetX: offset.0,
            offsetY: offset.1,
            properties: TextProperties.decode(node),
            visible: visible,
        )
    }
}
