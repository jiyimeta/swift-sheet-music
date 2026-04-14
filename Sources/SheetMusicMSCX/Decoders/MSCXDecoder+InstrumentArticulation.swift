import Foundation
import SheetMusicCore

extension InstrumentArticulation {
    static func decode(_ node: XMLNode) throws -> InstrumentArticulation {
        let name = node.attributes["name"]   // nil for default
        let velocity = Int(node.first("velocity")?.text ?? "100") ?? 100
        let gateTime = Int(node.first("gateTime")?.text ?? "100") ?? 100
        return InstrumentArticulation(name: name, velocity: velocity, gateTime: gateTime)
    }
}
