import Foundation
import SheetMusicCore

extension Tempo {
    static func decode(_ node: XMLNode) throws -> Tempo {
        let bps = Double(node.first("tempo")?.text ?? "2") ?? 2.0
        return Tempo(beatsPerSecond: bps)
    }
}
