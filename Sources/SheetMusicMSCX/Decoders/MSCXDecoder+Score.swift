import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Score {
    static func decode(_ root: XMLTreeNode) throws -> Score {
        guard root.name == "museScore" else {
            throw SheetMusicError.malformedScore(reason: "root is <\(root.name)>, expected <museScore>")
        }
        guard let scoreNode = root.first("Score") else {
            throw SheetMusicError.malformedScore(reason: "missing <Score>")
        }
        guard let divisionText = scoreNode.first("Division")?.text, let division = Int(divisionText) else {
            throw SheetMusicError.malformedScore(reason: "missing <Division>")
        }
        let parts = try scoreNode.all("Part").map { try Part.decode($0) }
        let staves = try scoreNode.all("Staff").map { try StaffContent.decode($0) }
        var metaTags: [String: String] = [:]
        for tag in scoreNode.all("metaTag") {
            if let name = tag.attributes["name"] {
                metaTags[name] = tag.text
            }
        }
        // Look for a leading `<VBox>` on staff 0 — that's where the
        // title / subtitle / composer block lives in MuseScore. Any
        // VBox that appears AFTER the first <Measure> is treated as
        // a section header and ignored for now (title-only minimal
        // port).
        var titleFrame: ScoreFrame?
        if let firstStaff = scoreNode.first("Staff") {
            for child in firstStaff.children {
                if child.name == "VBox" {
                    titleFrame = ScoreFrame.decode(vbox: child)
                    break
                }
                if child.name == "Measure" { break }
            }
        }
        let style: ScoreStyle
        if let styleNode = scoreNode.first("Style") {
            style = ScoreStyle.decode(style: styleNode)
        } else {
            style = .museScoreDefaults
        }
        return Score(
            division: division, parts: parts, staves: staves,
            metaTags: metaTags, titleFrame: titleFrame, style: style
        )
    }
}
