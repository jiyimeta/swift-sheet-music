import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Score {
    /// Build the `<museScore><Score>…</Score></museScore>` root.
    func encode(options: MSCXEncoderOptions = .init()) throws -> XMLTreeNode {
        var scoreChildren: [XMLTreeNode] = Self.layerHeader(options: options)
        scoreChildren.append(XMLTreeNode(
            name: "Division", text: String(division),
        ))
        scoreChildren.append(style.encode(options: options))
        scoreChildren.append(contentsOf: Self.showFlags(options: options))
        scoreChildren.append(contentsOf: encodedMetaTags(options: options))

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
                part.encodeDeclaration(partID: partID, staffIDs: ids, options: options),
            )
        }
        var titleFrameSlot = titleFrame
        for (part, _, ids) in allStaffIDs {
            for (staff, id) in zip(part.staves, ids) {
                let frame = titleFrameSlot
                titleFrameSlot = nil
                try scoreChildren.append(
                    staff.encodeTopLevel(staffID: id, titleFrame: frame, options: options),
                )
            }
        }

        let museScoreVersion: String
        switch options.targetVersion {
        case .v3: museScoreVersion = "3.02"
        case .v4: museScoreVersion = "4.60"
        }
        var rootChildren: [XMLTreeNode] = []
        if options.targetVersion == .v3 {
            rootChildren.append(XMLTreeNode(
                name: "programVersion", text: "3.6.2",
            ))
            rootChildren.append(XMLTreeNode(
                name: "programRevision", text: "3224f34",
            ))
        }
        rootChildren.append(XMLTreeNode(name: "Score", children: scoreChildren))
        return XMLTreeNode(
            name: "museScore",
            attributes: ["version": museScoreVersion],
            children: rootChildren,
        )
    }

    /// Leading `<LayerTag>` / `<currentLayer>` pair MuseScore 3 expects
    /// before `<Division>`. Empty for v4.
    private static func layerHeader(options: MSCXEncoderOptions) -> [XMLTreeNode] {
        guard options.targetVersion == .v3 else { return [] }
        return [
            XMLTreeNode(
                name: "LayerTag",
                attributes: ["id": "0", "tag": "default"],
            ),
            XMLTreeNode(name: "currentLayer", text: "0"),
        ]
    }

    /// `<show*>` visibility flags MuseScore 3 emits after `<Style>`.
    /// Empty for v4.
    private static func showFlags(options: MSCXEncoderOptions) -> [XMLTreeNode] {
        guard options.targetVersion == .v3 else { return [] }
        return [
            XMLTreeNode(name: "showInvisible", text: "1"),
            XMLTreeNode(name: "showUnprintable", text: "1"),
            XMLTreeNode(name: "showFrames", text: "1"),
            XMLTreeNode(name: "showMargins", text: "0"),
        ]
    }
}

extension Score {
    /// Emit `<metaTag>` children. v4 keeps the existing sorted-by-key
    /// emission; v3 emits the fixed 13-element canonical set MuseScore
    /// Studio expects, falling back to defaults for missing keys.
    private func encodedMetaTags(options: MSCXEncoderOptions) -> [XMLTreeNode] {
        switch options.targetVersion {
        case .v4:
            metaTags.keys.sorted().map { key in
                XMLTreeNode(
                    name: "metaTag",
                    attributes: ["name": key],
                    text: metaTags[key] ?? "",
                )
            }
        case .v3:
            Self.canonicalMS3MetaTagNames.map { name in
                XMLTreeNode(
                    name: "metaTag",
                    attributes: ["name": name],
                    text: ms3MetaValue(for: name),
                )
            }
        }
    }

    private func ms3MetaValue(for name: String) -> String {
        if let supplied = metaTags[name], !supplied.isEmpty { return supplied }
        switch name {
        case "creationDate": return Self.todayISODate
        case "platform": return "Apple Macintosh"
        default: return ""
        }
    }

    fileprivate static let canonicalMS3MetaTagNames: [String] = [
        "arranger", "composer", "copyright", "creationDate",
        "lyricist", "movementNumber", "movementTitle", "platform",
        "poet", "source", "translator", "workNumber", "workTitle",
    ]

    fileprivate static var todayISODate: String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: Date())
    }
}
