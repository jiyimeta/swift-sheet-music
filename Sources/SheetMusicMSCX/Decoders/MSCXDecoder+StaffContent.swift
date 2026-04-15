import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension StaffContent {
    static func decode(_ node: XMLTreeNode) throws -> StaffContent {
        guard let idText = node.attributes["id"], let id = Int(idText) else {
            throw SheetMusicError.malformedScore(reason: "Staff missing id attribute")
        }
        let measures = try node.all("Measure").map { try Measure.decode($0) }
        return StaffContent(id: id, measures: measures)
    }
}
