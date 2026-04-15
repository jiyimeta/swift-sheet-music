import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension StaffDeclaration {
    static func decode(_ node: XMLTreeNode) throws -> StaffDeclaration {
        let staffTypeNode = node.first("StaffType")
        let staffType = staffTypeNode?.first("name")?.text ?? "stdNormal"
        let group = staffTypeNode?.attributes["group"] ?? "pitched"
        return StaffDeclaration(staffType: staffType, group: group)
    }
}
