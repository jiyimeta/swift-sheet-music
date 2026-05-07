import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Score {
    /// Build the `<museScore><Score>…</Score></museScore>` root.
    func encode() -> XMLTreeNode {
        var scoreChildren: [XMLTreeNode] = []
        scoreChildren.append(XMLTreeNode(
            name: "Division", text: String(division)
        ))
        scoreChildren.append(style.encode())
        // metaTags are emitted in sorted key order for stable output.
        for key in metaTags.keys.sorted() {
            scoreChildren.append(XMLTreeNode(
                name: "metaTag",
                attributes: ["name": key],
                text: metaTags[key] ?? ""
            ))
        }

        // Synthesize stable per-staff IDs. Decoder pairs declared <Staff>
        // entries with top-level <Staff id="N"> bodies by id, so the
        // declaration and body must agree. Encoding `partID-staffIndex`
        // yields globally-unique strings even with multiple parts.
        var allStaffIDs: [(part: Part, ids: [String])] = []
        for part in parts {
            let ids = part.staves.indices.map { "\(part.id)-\($0)" }
            allStaffIDs.append((part, ids))
        }
        for (part, ids) in allStaffIDs {
            scoreChildren.append(part.encodeDeclaration(staffIDs: ids))
        }
        for (part, ids) in allStaffIDs {
            for (staff, id) in zip(part.staves, ids) {
                scoreChildren.append(staff.encodeTopLevel(staffID: id))
            }
        }

        return XMLTreeNode(
            name: "museScore",
            attributes: ["version": "4.60"],
            children: [
                XMLTreeNode(name: "Score", children: scoreChildren),
            ]
        )
    }
}
