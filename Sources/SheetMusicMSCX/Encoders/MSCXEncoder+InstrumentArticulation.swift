import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension InstrumentArticulation {
    func encode() -> XMLTreeNode {
        var attrs: [String: String] = [:]
        if let name { attrs["name"] = name }
        return XMLTreeNode(
            name: "Articulation",
            attributes: attrs,
            children: [
                XMLTreeNode(name: "velocity", text: String(velocity)),
                XMLTreeNode(name: "gateTime", text: String(gateTime)),
            ],
        )
    }
}
