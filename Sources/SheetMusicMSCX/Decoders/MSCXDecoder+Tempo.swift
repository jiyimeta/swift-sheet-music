import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Tempo {
    static func decode(_ node: XMLTreeNode) throws -> Tempo {
        let bps = Double(node.first("tempo")?.text ?? "2") ?? 2.0
        return Tempo(
            beatsPerSecond: bps,
            properties: TextProperties.decode(node)
        )
    }
}
