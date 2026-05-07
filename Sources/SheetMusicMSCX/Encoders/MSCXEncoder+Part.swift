import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Part {
    /// Build the `<Part id="...">` declaration block. The
    /// per-staff IDs passed in here must match the IDs used when
    /// emitting the top-level `<Staff id="...">` blocks at
    /// `Score.encode()` (otherwise the round-trip parser fails to
    /// pair declarations with bodies).
    func encodeDeclaration(staffIDs: [String]) -> XMLTreeNode {
        precondition(
            staffIDs.count == staves.count,
            "staffIDs must match staves count"
        )
        var children: [XMLTreeNode] = []
        for (staff, id) in zip(staves, staffIDs) {
            children.append(staff.encodeDeclaration(staffID: id))
        }
        if let trackName {
            children.append(XMLTreeNode(name: "trackName", text: trackName))
        }
        children.append(instrument.encode())
        return XMLTreeNode(
            name: "Part",
            attributes: ["id": id],
            children: children
        )
    }
}
