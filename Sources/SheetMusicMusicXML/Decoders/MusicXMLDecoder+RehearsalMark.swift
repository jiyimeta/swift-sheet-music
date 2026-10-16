import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

/// Decodes MusicXML `<direction-type><rehearsal>...</rehearsal>`
/// children. Mirrors MuseScore's importer
/// (`importmusicxmlpass2.cpp` — `m_rehearsalText` + `Factory::createRehearsalMark`).
enum MusicXMLRehearsalDecoder {
    /// Pull every rehearsal mark out of a single `<direction>`. A direction
    /// can in principle hold several `<rehearsal>` siblings (one per
    /// part), so we iterate — over every `<direction-type>`, as MuseScore's `directionType` reads each one.
    static func decode(_ direction: XMLTreeNode) -> [RehearsalMark] {
        var result: [RehearsalMark] = []
        for directionType in direction.all("direction-type") {
            for child in directionType.children where child.name == "rehearsal" {
                let frame = frameKind(
                    forEnclosure: child.attributes["enclosure"],
                )
                let carrier = MusicXMLFormattedWords.carrier(fromXMLText: xmlText(of: child))
                result.append(RehearsalMark(text: carrier.plain, frame: frame, preservedTextMarkup: carrier.markup))
            }
        }
        return result
    }

    /// MusicXML's `enclosure` attribute. `square` → rectangle (matches
    /// MuseScore default), `circle` → circle, `none` → none. Missing
    /// attribute defaults to rectangle, mirroring MuseScore's behavior
    /// when the importer doesn't see an explicit enclosure.
    private static func frameKind(
        forEnclosure raw: String?,
    ) -> TextFrameType {
        switch raw {
        case "circle": return .circle
        case "none": return .none
        case "square", nil, "rectangle": return .rectangle
        default: return .rectangle
        }
    }

    /// The mark's xml text as MuseScore sets it: the formatted text (`nextPartOfFormattedString`, `P2:4053`), with an
    /// empty `<b></b>` in front — "explicitly turn bold off" — unless it already holds `<b>` (`P2:3608-3610`).
    private static func xmlText(of node: XMLTreeNode) -> String {
        let xml = MusicXMLFormattedWords.xmlText(of: node)
        return xml.hasSubstring("<b>") ? xml : "<b></b>" + xml
    }
}
