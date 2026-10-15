import SheetMusicCore
import SheetMusicFoundation
import SheetMusicXMLTools

extension StaffText {
    /// `<PlayTechAnnotation>` and `<HarpPedalDiagram>` are staff-text-like (`StaffTextBase` / `TextBase`): their text,
    /// offset, color and font children read as a staff text's do, and their own properties become the annotation
    /// (`TRead::read(PlayTechAnnotation*)`, `rw/read460/tread.cpp:919-933`; `TRead::read(HarpPedalDiagram*)`,
    /// `tread.cpp:3038-3059`).
    static func decodeAnnotated(_ node: XMLTreeNode) throws -> StaffText {
        var text = try decode(node, isSystemText: false)
        switch node.name {
        case "PlayTechAnnotation":
            // An absent `<playTechType>` is MuseScore's property default, natural; `<play>` defaults to true.
            let technique = node.first("playTechType").map { PlayingTechnique(mscxToken: $0.text) } ?? .natural
            text.annotation = .playTechnique(technique, playsBack: node.first("play")?.text != "0")
        case "HarpPedalDiagram":
            var diagram = HarpPedalDiagram()
            diagram.isDiagram = node.first("isDiagram")?.text != "0"
            for string in node.first("pedalState")?.all("string") ?? [] {
                guard let index = string.attributes["name"].flatMap(Int.init), diagram.pedals.indices.contains(index),
                      let ordinal = Int(string.text)
                else { continue }
                diagram.pedals[index] = HarpPedalDiagram.Position(mscxOrdinal: ordinal)
            }
            text.annotation = .harpPedal(diagram)
        default:
            break
        }
        return text
    }

    /// The technique MuseScore 4 turns a MuseScore 3 staff text into on load
    /// (`CompatUtils::replaceStaffTextWithPlayTechniqueAnnotation`, `rw/compat/compatutils.cpp:190-271`, run for a
    /// file older than 4.00): its plain text lower-cased, else its voice-1 channel switch's name lower-cased, looked up
    /// in the old Staff Text Properties dialog's channel names. `nil` when neither names one.
    static func legacyTechnique(of node: XMLTreeNode) -> PlayingTechnique? {
        if let technique = node.first("text").flatMap({ legacyTechniques[plainText(of: $0).lowercased()] }) {
            return technique
        }
        // `channelName(0)`: the last switch addressed to voice 1 or, with no `voice` attribute, to every voice
        // (`TRead::readProperties(StaffTextBase*)`, `rw/read400/tread.cpp:516-527`).
        let channel = node.children.last { child in
            (child.name == "channelSwitch" || child.name == "articulationChange")
                && (child.attributes["voice"] ?? "0") == "0"
        }?.attributes["name"]
        guard let channel, !channel.isEmpty else { return nil }
        return legacyTechniques[channel.lowercased()]
    }

    private static let legacyTechniques: [String: PlayingTechnique] = [
        "natural": .natural, "normal": .natural, "open": .open, "mute": .mute, "distortion": .distortion,
        "overdriven": .overdrive, "harmonics": .harmonics, "jazz": .jazzTone, "arco": .natural,
        "pizzicato": .pizzicato, "tremolo": .tremolo,
    ]
}
