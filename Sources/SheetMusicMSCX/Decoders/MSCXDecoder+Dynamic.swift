import Foundation
import SheetMusicCore

extension Dynamic {
    /// Default-to-mf-velocity table for symbolic dynamics when `<velocity>` is absent.
    /// Mirrors MuseScore default dynamic velocities.
    private static let defaultVelocity: [String: Int] = [
        "ppppp": 5, "pppp": 10, "ppp": 16, "pp": 33, "p": 49,
        "mp": 64, "mf": 80, "f": 96, "ff": 112, "fff": 126, "ffff": 127, "fffff": 127,
    ]

    static func decode(_ node: XMLNode) throws -> Dynamic {
        let subtype = node.first("subtype")?.text ?? "mf"
        let velocity: Int
        if let vText = node.first("velocity")?.text, let v = Int(vText) {
            velocity = v
        } else {
            velocity = defaultVelocity[subtype] ?? 80
        }
        return Dynamic(subtype: subtype, velocity: velocity)
    }
}
