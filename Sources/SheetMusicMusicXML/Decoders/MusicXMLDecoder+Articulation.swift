import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension MusicXMLNoteDecoder {
    /// A note's `<notations><articulations>` and the articulation-like marks under `<technical>`, in document order,
    /// each kind once. C++: `convertArticulationToSymId` + `MusicXmlParserNotations::articulations()` / `technical()`
    /// (`importmusicxmlpass2.cpp`).
    ///
    /// Two departures from that table: `detached-legato` is the one louré (`.tenutoStaccato`) rather than the tenuto
    /// plus staccato MuseScore 4 splits it into, and only the marks `ChordArticulation.Kind` models are read —
    /// `thumb-position`, the tonguings, the brass bends and the handbell marks stay unread, as does everything else
    /// under `<technical>` (fingering, string, fret). A `harmonic` is the string harmonic unless it is `artificial`,
    /// which MuseScore drops too (`harmonic()`).
    static func decodeArticulations(_ node: XMLTreeNode) -> [ChordArticulation] {
        guard let notations = node.first("notations") else { return [] }
        var result: [ChordArticulation] = []
        for group in notations.children where group.name == "articulations" || group.name == "technical" {
            for mark in group.children {
                guard let kind = articulationKind(forMusicXML: mark),
                      !result.contains(where: { $0.kind == kind })
                else { continue }
                result.append(ChordArticulation(kind: kind, anchor: kind.hasPlacementVariants ? anchor(mark) : nil))
            }
        }
        return result
    }

    private static func articulationKind(forMusicXML mark: XMLTreeNode) -> ChordArticulation.Kind? {
        switch mark.name {
        case "harmonic": mark.children.contains { $0.name == "artificial" } ? nil : .harmonic
        case "accent": .accent
        case "strong-accent": .marcato
        case "staccato": .staccato
        case "tenuto": .tenuto
        case "detached-legato": .tenutoStaccato
        case "staccatissimo": .staccatissimo
        case "spiccato": .staccatissimoStroke
        case "stress": .stress
        case "unstress": .unstress
        case "soft-accent": .softAccent
        case "up-bow": .upBow
        case "down-bow": .downBow
        case "stopped": .muteClosed
        case "open", "open-string": .muteOpen
        default: nil
        }
    }

    /// `placement` names the side; without it, a `type` of `up` / `down` (which `strong-accent` carries) implies
    /// above / below — MuseScore's `addArticulationToChord`. `nil` when neither says.
    private static func anchor(_ mark: XMLTreeNode) -> ChordArticulation.Anchor? {
        switch mark.attributes["placement"] ?? mark.attributes["type"] {
        case "above", "up": .above
        case "below", "down": .below
        default: nil
        }
    }
}
