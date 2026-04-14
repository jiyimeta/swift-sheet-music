import Foundation
import SheetMusicCore

extension Score {
    static func decode(_ root: XMLNode) throws -> Score {
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
        return Score(division: division, parts: parts, staves: staves, metaTags: metaTags)
    }
}
