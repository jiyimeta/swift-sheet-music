import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Score {
    static func decode(_ root: XMLTreeNode) throws -> Score {
        guard root.name == "museScore" else {
            throw SheetMusicError.malformedScore(
                reason:
                "root is <\(root.name)>, expected <museScore>",
            )
        }
        guard let scoreNode = root.first("Score") else {
            throw SheetMusicError.malformedScore(reason: "missing <Score>")
        }
        guard let divisionText = scoreNode.first("Division")?.text,
              let division = Int(divisionText)
        else {
            throw SheetMusicError.malformedScore(reason: "missing <Division>")
        }

        let partPairings = try scoreNode.all("Part").enumerated().map {
            try Part.decodePairing($0.element, fallbackIndex: $0.offset + 1)
        }
        let topLevelStaves = try scoreNode.all("Staff").map {
            try MSCXTopLevelStaff.decode($0)
        }
        let parts = try assembleParts(
            decoded: partPairings, topLevel: topLevelStaves,
        )

        var metaTags: [String: String] = [:]
        for tag in scoreNode.all("metaTag") {
            if let name = tag.attributes["name"] {
                metaTags[name] = tag.text
            }
        }

        // VBox under the first top-level Staff (= first Part's first Staff).
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
        let version = detectVersion(root: root, scoreNode: scoreNode)
        return Score(
            division: division, parts: parts,
            metaTags: metaTags, titleFrame: titleFrame, style: style,
            source: .museScore(version),
        )
    }

    /// Detect MuseScore wire-format major version from the
    /// `<museScore version="…">` attribute. Falls back to `<programVersion>`
    /// (used by 3.x exports) and finally defaults to `.v4` when no
    /// recognisable marker is present.
    private static func detectVersion(
        root: XMLTreeNode, scoreNode: XMLTreeNode,
    ) -> MSCXVersion {
        if let versionAttr = root.attributes["version"],
           let major = versionAttr.split(separator: ".").first,
           let majorInt = Int(major)
        {
            return majorInt <= 3 ? .v3 : .v4
        }
        if let programVersion = scoreNode.first("programVersion")?.text,
           programVersion.hasPrefix("3.")
        {
            return .v3
        }
        return .v4
    }
}
