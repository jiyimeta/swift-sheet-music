import Foundation
import SheetMusicCore
import SheetMusicXMLTools

/// Decodes MusicXML `<direction-type><rehearsal>...</rehearsal>`
/// children. Mirrors MuseScore's importer
/// (`importmusicxmlpass2.cpp` — `m_rehearsalText` + `Factory::createRehearsalMark`).
enum MusicXMLRehearsalDecoder {
    /// Pull every rehearsal mark out of a single `<direction>`. A direction
    /// can in principle hold several `<rehearsal>` siblings (one per
    /// part), so we iterate.
    static func decode(_ direction: XMLTreeNode) -> [RehearsalMark] {
        guard let directionType = direction.first("direction-type") else {
            return []
        }
        var result: [RehearsalMark] = []
        for child in directionType.children where child.name == "rehearsal" {
            let text = plainText(of: child)
            let frame = frameKind(
                forEnclosure: child.attributes["enclosure"],
            )
            result.append(RehearsalMark(text: text, frame: frame))
        }
        return result
    }

    /// MusicXML's `enclosure` attribute. `square` → rectangle (matches
    /// MuseScore default), `circle` → circle, `none` → none. Missing
    /// attribute defaults to rectangle, mirroring MuseScore's behavior
    /// when the importer doesn't see an explicit enclosure.
    private static func frameKind(
        forEnclosure raw: String?,
    ) -> RehearsalMark.FrameKind {
        switch raw {
        case "circle": return .circle
        case "none": return .none
        case "square", nil, "rectangle": return .rectangle
        default: return .rectangle
        }
    }

    private static func plainText(of node: XMLTreeNode) -> String {
        var result = node.text
        for child in node.children {
            result += plainText(of: child)
        }
        return result
    }
}
