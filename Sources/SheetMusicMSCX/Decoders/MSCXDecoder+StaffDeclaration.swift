import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension StaffDeclaration {
    static func decode(_ node: XMLTreeNode) throws -> StaffDeclaration {
        let staffTypeNode = node.first("StaffType")
        let staffType = staffTypeNode?.first("name")?.text ?? "stdNormal"
        let group = staffTypeNode?.attributes["group"] ?? "pitched"
        let defaultClef = node.first("defaultClef")?.text
        return StaffDeclaration(
            staffType: staffType,
            group: group,
            defaultClefType: defaultClef
        )
    }
}
