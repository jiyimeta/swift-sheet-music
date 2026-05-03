import Foundation
import SheetMusicCore
import SheetMusicXMLTools

extension Score {
    /// Decode a parsed MusicXML root node into a `Score`.
    /// Rejects `<score-timewise>` with an explicit error; the rest of the
    /// library assumes the partwise layout.
    static func decodeMusicXML(_ root: XMLTreeNode) throws -> Score {
        switch root.name {
        case "score-partwise":
            break
        case "score-timewise":
            throw SheetMusicError.malformedScore(
                reason: "MusicXML: unsupported <score-timewise> variant"
            )
        default:
            throw SheetMusicError.malformedScore(
                reason: "MusicXML: <score-partwise> root element not found"
            )
        }

        let metaTags = decodeMetaTags(root)

        guard let partList = root.first("part-list") else {
            throw SheetMusicError.malformedScore(
                reason: "MusicXML: <part-list> is required"
            )
        }
        let parts = try decodeParts(root: root, partList: partList)

        // Hard-code division = 480 ticks per quarter, matching MuseScore's default
        // and the `*_ref.mscx` fixtures we semantic-compare against. MusicXML's
        // own `<divisions>` is part-local and would vary per fixture.
        return Score(division: 480, parts: parts, metaTags: metaTags)
    }

    /// MusicXML carries metadata in `<work>`, `<identification>`, and `<credit>`.
    /// We surface the stable fields that map directly to MuseScore's `metaTag`
    /// names: `workTitle`, `workNumber`, `movementTitle`, `movementNumber`,
    /// `composer`, `lyricist`, `arranger`, `copyright`, `source`, `translator`.
    /// Credit-geometry inference is explicitly out of scope.
    private static func decodeMetaTags(_ root: XMLTreeNode) -> [String: String] {
        var tags: [String: String] = [:]
        if let work = root.first("work") {
            if let title = work.first("work-title")?.text, !title.isEmpty {
                tags["workTitle"] = title
            }
            if let number = work.first("work-number")?.text, !number.isEmpty {
                tags["workNumber"] = number
            }
        }
        if let title = root.first("movement-title")?.text, !title.isEmpty {
            tags["movementTitle"] = title
        }
        if let number = root.first("movement-number")?.text, !number.isEmpty {
            tags["movementNumber"] = number
        }
        if let id = root.first("identification") {
            for creator in id.all("creator") {
                let type = creator.attributes["type"] ?? "composer"
                let value = creator.text
                guard !value.isEmpty else { continue }
                switch type {
                case "composer", "lyricist", "arranger":
                    tags[type] = value
                default:
                    // Unknown creator types (e.g. "editor") are out of seed scope.
                    continue
                }
            }
            let rights = id.all("rights")
                .map(\.text)
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            if !rights.isEmpty {
                tags["copyright"] = rights
            }
            if let source = id.first("source")?.text, !source.isEmpty {
                tags["source"] = source
            }
            if let misc = id.first("miscellaneous") {
                for field in misc.all("miscellaneous-field") {
                    guard let key = field.attributes["name"], !key.isEmpty else { continue }
                    let value = field.text
                    guard !value.isEmpty else { continue }
                    tags[key] = value
                }
            }
        }
        return tags
    }

    /// Walk the top-level `<part>` elements, detect per-part staff count from
    /// the first `<attributes><staves>`, and build `Part` with its `Staff`
    /// measures populated inline. One `Part` per `<part>`; one `Staff` per
    /// staff (so a piano part produces a `Part` with 2 `Staff`s).
    private static func decodeParts(
        root: XMLTreeNode,
        partList: XMLTreeNode
    ) throws -> [Part] {
        let scoreParts = partList.all("score-part")
        var parts: [Part] = []
        for (index, partNode) in root.all("part").enumerated() {
            let id = partNode.attributes["id"] ?? ""
            guard let scorePart = scoreParts.first(where: { $0.attributes["id"] == id })
                ?? (index < scoreParts.count ? scoreParts[index] : nil)
            else {
                throw SheetMusicError.malformedScore(
                    reason: "MusicXML: <part id='\(id)'> has no matching <score-part>"
                )
            }
            // Build the percussion table from the score-part header BEFORE
            // walking measures — the walker must hand it to the note decoder
            // so <unpitched> notes resolve to GM drum pitches.
            let prelimDrumTable = MusicXMLDrumTable.build(scorePart: scorePart)
            let walker = try MusicXMLMeasureWalker.decode(
                partNode: partNode,
                drumTable: prelimDrumTable
            )
            let (partTemplate, _) = try Part.decodeMusicXML(
                scorePart: scorePart,
                partId: id,
                staffCount: walker.staffCount
            )
            // Replace the placeholder empty-measure staves with real content.
            let populatedStaves: [Staff] = walker.measuresByStaff.map { staffMeasures in
                Staff(
                    staffType: "stdNormal", group: "pitched",
                    defaultClefType: nil, measures: staffMeasures
                )
            }
            let part = Part(
                id: partTemplate.id,
                trackName: partTemplate.trackName,
                instrument: partTemplate.instrument,
                staves: populatedStaves
            )
            parts.append(part)
        }
        return parts
    }
}
