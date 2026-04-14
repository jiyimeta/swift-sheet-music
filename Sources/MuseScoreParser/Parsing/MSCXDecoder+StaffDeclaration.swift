import Foundation

extension StaffDeclaration {
    static func decode(_ node: XMLNode) throws -> StaffDeclaration {
        let staffTypeNode = node.first("StaffType")
        let staffType = staffTypeNode?.first("name")?.text ?? "stdNormal"
        let group = staffTypeNode?.attributes["group"] ?? "pitched"
        return StaffDeclaration(staffType: staffType, group: group)
    }
}
