import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Score {
    /// Build the `<museScore><Score>…</Score></museScore>` root.
    func encode() throws -> XMLTreeNode {
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

        // Synthesize sequential 1-based integer IDs for parts and
        // staves. MuseScore Studio's loader expects numeric IDs and
        // refuses (or crashes on) tokens like "P0" / "P0-0" that
        // hand-built `Score` values often carry. The decoder pairs
        // declarations with bodies by string equality, so any
        // consistent scheme round-trips; sequential integers also
        // match MuseScore's own writer output.
        var allStaffIDs: [(part: Part, partID: String, ids: [String])] = []
        var nextStaffID = 1
        for (partIndex, part) in parts.enumerated() {
            let partID = String(partIndex + 1)
            let ids = part.staves.indices.map { _ -> String in
                let id = String(nextStaffID)
                nextStaffID += 1
                return id
            }
            allStaffIDs.append((part, partID, ids))
        }
        for (part, partID, ids) in allStaffIDs {
            scoreChildren.append(
                part.encodeDeclaration(partID: partID, staffIDs: ids))
        }
        var titleFrameSlot = titleFrame
        for (part, _, ids) in allStaffIDs {
            for (staff, id) in zip(part.staves, ids) {
                let frame = titleFrameSlot
                titleFrameSlot = nil
                try scoreChildren.append(
                    staff.encodeTopLevel(staffID: id, titleFrame: frame)
                )
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
