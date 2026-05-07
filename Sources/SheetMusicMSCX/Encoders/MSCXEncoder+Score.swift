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
        return XMLTreeNode(
            name: "museScore",
            attributes: ["version": "4.60"],
            children: [
                XMLTreeNode(name: "Score", children: scoreChildren),
            ]
        )
    }
}
