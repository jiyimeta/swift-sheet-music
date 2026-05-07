import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Staff {
    /// Encode the per-Part `<Staff>` declaration block — staff type,
    /// bracket information, default clef. Measures are emitted by
    /// `encodeTopLevel(staffID:)` separately.
    func encodeDeclaration(staffID: String) -> XMLTreeNode {
        var children: [XMLTreeNode] = []
        children.append(XMLTreeNode(
            name: "StaffType",
            attributes: ["group": group],
            children: [
                XMLTreeNode(name: "name", text: staffType),
            ]
        ))
        if let defaultClefType {
            children.append(XMLTreeNode(
                name: "defaultClef", text: defaultClefType
            ))
        }
        for bracket in brackets {
            var bracketAttrs: [String: String] = [
                "type": String(bracket.type.rawValue),
                "span": String(bracket.span),
                "col": String(bracket.column),
            ]
            if !bracket.visible { bracketAttrs["visible"] = "0" }
            children.append(XMLTreeNode(
                name: "bracket", attributes: bracketAttrs
            ))
        }
        return XMLTreeNode(
            name: "Staff",
            attributes: ["id": staffID],
            children: children
        )
    }

    /// Encode the top-level `<Staff id="N">` block carrying measures.
    func encodeTopLevel(staffID: String) -> XMLTreeNode {
        XMLTreeNode(
            name: "Staff",
            attributes: ["id": staffID],
            children: measures.map { $0.encode() }
        )
    }
}
